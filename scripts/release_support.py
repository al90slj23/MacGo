#!/usr/bin/env python3
"""Mac Go release identities and atomic private receipts; no hardware writes.

Source identity covers the working tree that will exist after an exact commit.
Builds, local retrieval artifacts, logs and the independent ZERO clone are ignored.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess


class ReleaseError(RuntimeError):
    pass


def command(root, *args, capture=True, timeout=180, env=None):
    result = subprocess.run(args, cwd=root, text=True, timeout=timeout, env=env,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        detail = (result.stderr or result.stdout or '').strip()
        raise ReleaseError(f'{args[0]} 失败（{result.returncode}）：{detail}')
    return result.stdout.strip() if capture else ''


def git(root, *args):
    return command(root, 'git', *args)


def git_paths(root, *args):
    return [os.fsdecode(raw) for raw in subprocess.check_output(
        ['git', *args, '-z'], cwd=root).split(b'\0') if raw]


def visible_paths(root):
    return sorted(set(git_paths(root, 'ls-files', '--cached', '--others', '--exclude-standard')))


def changed_paths(root):
    return sorted(set(git_paths(root, 'diff', 'HEAD', '--name-only') +
                      git_paths(root, 'ls-files', '--others', '--exclude-standard')))


def hash_paths(root, paths):
    digest = hashlib.sha256()
    for relative in sorted(paths):
        path = root / relative
        if not path.exists() and not path.is_symlink():
            continue  # A committed deletion and its pre-commit tree are identical.
        digest.update(os.fsencode(relative) + b'\0')
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            digest.update(b'link\0' + os.fsencode(os.readlink(path)))
        elif stat.S_ISREG(mode):
            digest.update(b'executable\0' if mode & 0o111 else b'file\0')
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
        else:
            raise ReleaseError(f'非普通发布文件：{relative}')
        digest.update(b'\0')
    return digest.hexdigest()


def source_fingerprint(root):
    return hash_paths(root, visible_paths(root))


def directory_fingerprint(directory):
    if not directory.is_dir() or directory.is_symlink():
        raise ReleaseError(f'应用包不存在或是软链：{directory}')
    paths = [str(p.relative_to(directory)) for p in directory.rglob('*')
             if (not p.is_dir() or p.is_symlink()) and p.name != '.DS_Store']
    return hash_paths(directory, paths)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f'.{os.getpid()}.tmp')
    with temporary.open('w') as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    temporary.replace(path)


def bundle_info(app):
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())


def seal_bundle(root, app, fingerprint):
    info_path = app / 'Contents/Info.plist'
    info = bundle_info(app)
    info.update(MacGoSourceRevision=git(root, 'rev-parse', 'HEAD'),
                MacGoSourceFingerprint=fingerprint,
                MacGoSourceDirty=bool(changed_paths(root)))
    info_path.write_bytes(plistlib.dumps(info))
    # Respect the same signing identity as build-app.sh; never downgrade it.
    command(root, '/usr/bin/codesign', '--force', '--options', 'runtime', '--sign',
            os.environ.get('CODE_SIGN_IDENTITY', '-'), '--identifier',
            'local.mactoolbox.app', str(app))
    command(root, '/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    return {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
            'revision': info['MacGoSourceRevision'], 'source_fingerprint': fingerprint,
            'source_dirty': info['MacGoSourceDirty'],
            'bundle_fingerprint': directory_fingerprint(app)}


def public_source_check(root):
    """Fail before any Git mutation for private/generated or unexpected payloads."""
    allowed_roots = {'Sources', 'Tests', 'Resources', 'scripts', 'docs', '.ai', '.github'}
    allowed_files = {'AGENTS.md', 'README.md', 'THIRD_PARTY_NOTICES.md', 'LICENSE',
                     'Package.swift', 'Package.resolved', '.gitignore', 'gogogo.sh'}
    failures = []
    visible = set(visible_paths(root))
    for relative in visible:
        path = root / relative
        if not path.exists() and not path.is_symlink():
            continue
        parts = Path(relative).parts
        if parts[0] not in allowed_roots and relative not in allowed_files:
            failures.append(f'未列入公开源码范围：{relative}'); continue
        if any(p in ('.generated', 'backups', 'node_modules', '__pycache__') or
               p.endswith('.app') for p in parts) or path.suffix in ('.log', '.dmg', '.zip', '.gguf', '.sqlite'):
            failures.append(f'本地/生成文件禁止公开：{relative}'); continue
        if path.is_symlink():
            target = os.readlink(path)
            immediate = Path(os.path.abspath(path.parent / target))
            if os.path.isabs(target) or not path.resolve().is_relative_to(root.resolve()):
                failures.append(f'公开链接越出仓库：{relative}')
            elif (path.is_dir() or not immediate.is_relative_to(root.resolve()) or
                  str(immediate.relative_to(root.resolve())) not in visible or
                  str(path.resolve().relative_to(root.resolve())) not in visible):
                failures.append(f'公开链接必须指向受版本管理的普通源文件：{relative}')
        elif path.is_file() and path.suffix in ('.md', '.json', '.toml', '.sh', '.py', '.swift', '.yml', '.yaml'):
            content = path.read_text(errors='replace')
            # Actual account/home paths must not enter a public source archive.
            private_prefixes = (str(root), str(Path.home()))
            if any(prefix != '/' and prefix in content for prefix in private_prefixes):
                failures.append(f'含本机私密绝对路径：{relative}')
            if any(('-----BEGIN ' + kind + '-----') in content
                   for kind in ('PRIVATE KEY', 'OPENSSH PRIVATE KEY', 'RSA PRIVATE KEY')):
                failures.append(f'含私钥内容：{relative}')
    if failures:
        raise ReleaseError('\n'.join(failures))
