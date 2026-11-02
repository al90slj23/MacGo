#!/usr/bin/env python3
"""Disposable Git fixtures and failure-boundary checks; never launch a real app."""
import contextlib
from datetime import datetime, timezone
import io
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release
from release_support import (ReleaseError, changed_paths, directory_fingerprint,
                             git, public_source_check, source_fingerprint, write_json)


class GitFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(['git', 'init', '-q', '-b', 'main'], cwd=self.root, check=True)
        git(self.root, 'config', 'user.name', 'Fixture')
        git(self.root, 'config', 'user.email', 'fixture@example.invalid')
        (self.root / '.gitignore').write_text('dist/\nZERO/\n')
        (self.root / 'README.md').write_text('fixture\n')
        git(self.root, 'add', '--', '.gitignore', 'README.md')
        git(self.root, 'commit', '-qm', 'initial')

    def test_ignored_template_and_build_never_enter_source(self):
        before = source_fingerprint(self.root)
        for folder in ('ZERO', 'dist'):
            (self.root / folder).mkdir()
            (self.root / folder / 'private.txt').write_text('local')
        self.assertEqual(source_fingerprint(self.root), before)
        self.assertEqual(changed_paths(self.root), [])

    def test_new_content_and_executable_bits_invalidate_source(self):
        before = source_fingerprint(self.root)
        script = self.root / 'gogogo.sh'
        script.write_text('#!/bin/bash\n')
        added = source_fingerprint(self.root)
        self.assertNotEqual(added, before)
        script.chmod(0o755)
        self.assertNotEqual(source_fingerprint(self.root), added)

    def test_deleted_source_has_same_identity_after_commit(self):
        (self.root / 'README.md').unlink()
        fingerprint = source_fingerprint(self.root)
        candidate = changed_paths(self.root)
        tree = release.stage_candidate(self.root, candidate, fingerprint)
        git(self.root, 'commit', '-qm', 'delete')
        self.assertEqual(git(self.root, 'rev-parse', 'HEAD^{tree}'), tree)
        self.assertEqual(source_fingerprint(self.root), fingerprint)

    def test_preexisting_staged_work_is_preserved(self):
        (self.root / 'README.md').write_text('another task')
        git(self.root, 'add', '--', 'README.md')
        tree = git(self.root, 'write-tree')
        with self.assertRaises(ReleaseError):
            release.stage_candidate(self.root, changed_paths(self.root), source_fingerprint(self.root))
        self.assertEqual(git(self.root, 'write-tree'), tree)

    def test_new_file_after_validation_is_not_staged(self):
        (self.root / 'README.md').write_text('candidate')
        candidate, fingerprint = changed_paths(self.root), source_fingerprint(self.root)
        (self.root / 'LICENSE').write_text('late unrelated work')
        with self.assertRaises(ReleaseError):
            release.stage_candidate(self.root, candidate, fingerprint)
        self.assertEqual(git(self.root, 'diff', '--cached', '--name-only'), '')

    def test_public_guard_rejects_private_path_and_external_link(self):
        (self.root / 'README.md').write_text(str(Path.home()) + '/private')
        with self.assertRaises(ReleaseError):
            public_source_check(self.root)
        (self.root / 'README.md').write_text('clean')
        (self.root / 'LICENSE').symlink_to('/etc/hosts')
        with self.assertRaises(ReleaseError):
            public_source_check(self.root)

    def test_public_guard_rejects_generated_payload(self):
        generated = self.root / '.ai/L5#Knowledge/.generated'
        generated.mkdir(parents=True)
        (generated / 'record.json').write_text('{}')
        with self.assertRaises(ReleaseError):
            public_source_check(self.root)

    def test_public_symlink_cannot_hide_ignored_build_input(self):
        target = self.root / 'dist/local.py'
        target.parent.mkdir()
        target.write_text('untracked build input')
        scripts = self.root / 'scripts'
        scripts.mkdir()
        (scripts / 'part.py').symlink_to('../dist/local.py')
        with self.assertRaises(ReleaseError):
            public_source_check(self.root)

    def test_wrong_remote_never_fetches(self):
        git(self.root, 'remote', 'add', 'origin', 'https://github.com/example/other.git')
        with patch.object(release, 'ROOT', self.root), self.assertRaises(ReleaseError):
            release.preflight(publish=True)

    def test_literal_push_destination_cannot_be_rewritten(self):
        destination = 'https://github.com/al90slj23/MacGo.git'
        release.check_destination(self.root, destination)
        git(self.root, 'config', 'url.https://example.invalid/.pushInsteadOf', destination)
        with self.assertRaises(ReleaseError):
            release.check_destination(self.root, destination)

    def test_bundle_content_and_mode_changes_invalidate_receipt(self):
        app = self.root / 'dist/Mac Go.app'
        executable = app / 'Contents/MacOS/MacGo'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'app')
        before = directory_fingerprint(app)
        executable.chmod(0o755)
        self.assertNotEqual(directory_fingerprint(app), before)

    def test_stale_head_rejects_install_receipt(self):
        app = self.root / 'dist/Mac Go.app'
        app.mkdir(parents=True)
        receipt = self.root / 'dist/validated.json'
        write_json(receipt, {'validated': True, 'revision': 'old',
                            'source_fingerprint': source_fingerprint(self.root),
                            'bundle_fingerprint': directory_fingerprint(app)})
        with patch.multiple(release, ROOT=self.root, APP=app, RECEIPT=receipt):
            with self.assertRaises(ReleaseError):
                release.checked_receipt()


class RuntimeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.expected = {'version': '1', 'build': '2', 'revision': 'abc',
                         'source_fingerprint': 'hash', 'source_dirty': False}
        self.status = {'pid': 12345, 'uid': os.getuid(),
                       'executablePath': str(release.INSTALLED / 'Contents/MacOS/MacGo'),
                       'updatedAt': datetime.now(timezone.utc).isoformat(),
                       'version': '1', 'build': '2', 'sourceRevision': 'abc',
                       'sourceFingerprint': 'hash', 'sourceDirty': False}

    def accepted(self, query=lambda *_: True):
        return release.verify_runtime(self.status, self.expected, 1, 999, query)

    def test_success_requires_independent_live_process(self):
        self.assertTrue(self.accepted())
        self.assertFalse(self.accepted(lambda *_: False))

    def test_old_or_wrong_identity_is_rejected(self):
        for field, value in [('uid', os.getuid() + 1), ('pid', 999),
                             ('sourceRevision', 'old'), ('executablePath', '/tmp/MacGo'),
                             ('updatedAt', '1970-01-01T00:00:00Z')]:
            with self.subTest(field=field), patch.dict(self.status, {field: value}):
                self.assertFalse(self.accepted())


class PipelineTests(unittest.TestCase):
    def run_failure(self, failed_stage, args):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            mocks = {}
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(release, 'STATE', state))
                for name in ('preflight', 'validate', 'commit_and_push', 'install_validated'):
                    mocks[name] = stack.enter_context(patch.object(release, name))
                mocks[failed_stage].side_effect = ReleaseError('fixture failure')
                with self.assertRaises(ReleaseError), contextlib.redirect_stdout(io.StringIO()):
                    release.main(args)
            return mocks

    def test_validation_failure_never_pushes_or_installs(self):
        mocks = self.run_failure('validate', ['1', '1', 'd'])
        mocks['commit_and_push'].assert_not_called()
        mocks['install_validated'].assert_not_called()

    def test_push_failure_never_installs(self):
        mocks = self.run_failure('commit_and_push', ['1', '1', 'd'])
        mocks['install_validated'].assert_not_called()

    def test_local_update_never_commits_or_pushes(self):
        mocks = self.run_failure('install_validated', ['0'])
        mocks['commit_and_push'].assert_not_called()

    def test_noninteractive_no_arguments_has_no_side_effects(self):
        with patch('sys.stdin.isatty', return_value=False), patch.object(release, 'preflight') as preflight:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(release.main([]), 0)
            preflight.assert_not_called()

    def test_concurrent_mutation_lock_refuses_second_process(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(release, 'STATE', Path(temporary)):
            with release.release_lock(), self.assertRaises(ReleaseError):
                with release.release_lock():
                    self.fail('second lock acquired')


if __name__ == '__main__':
    unittest.main()
