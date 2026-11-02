#!/usr/bin/env python3
"""Mac Go: validation, exact-file GitHub publication, and local App update.

No online deployment. A validated source+bundle receipt gates installation; native
lifecycle shutdown precedes atomic installer and fresh owned-process verification.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from release_support import (ReleaseError, bundle_info, changed_paths, command,
                             directory_fingerprint, git, git_paths, public_source_check,
                             read_json, seal_bundle, source_fingerprint, write_json)

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'dist/Mac Go.app'
INSTALLED = Path.home() / 'Applications/Mac Go.app'
RUNTIME = Path.home() / 'Library/Application Support/MacGo/runtime-status.json'
STATE = ROOT / 'dist/gogogo'
RECEIPT = STATE / 'validated.json'
REPOSITORY = 'al90slj23/MacGo'
BRANCH = 'main'


@contextmanager
def release_lock():
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / 'release.lock').open('a') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ReleaseError('另一个 Mac Go 检查或更新仍在执行。')
        yield


class Run:
    def __init__(self):
        self.path = STATE / (datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid()))
        self.path.mkdir(parents=True)
        self.evidence = {'status': 'running', 'steps': []}

    @contextmanager
    def step(self, name):
        print(f'\n[{len(self.evidence["steps"]) + 1}] {name}', flush=True)
        started = time.monotonic()
        entry = {'name': name, 'status': 'running'}
        self.evidence['steps'].append(entry)
        try:
            yield
            entry['status'] = 'passed'
        except BaseException:
            entry['status'] = 'failed'
            raise
        finally:
            entry['seconds'] = round(time.monotonic() - started, 2)
            write_json(self.path / 'result.json', self.evidence)

    def logged(self, filename, *args, env=None):
        log = self.path / filename
        print(f'日志：{log.relative_to(ROOT)}', flush=True)
        with log.open('w') as stream:
            result = subprocess.run(args, cwd=ROOT, env=env, stdout=stream,
                                    stderr=subprocess.STDOUT)
        if result.returncode:
            print('\n'.join(log.read_text(errors='replace').splitlines()[-35:]), file=sys.stderr)
            raise ReleaseError(f'{filename} 未通过（{result.returncode}），详情见本地日志。')


def assert_stable(fingerprint):
    if source_fingerprint(ROOT) != fingerprint:
        raise ReleaseError('验证期间源码发生变化；已停止，请重新检查。')


def preflight(publish=False):
    if os.getuid() == 0:
        raise ReleaseError('请以当前登录用户运行，不要使用 sudo。')
    if git(ROOT, 'rev-parse', '--show-toplevel') != str(ROOT):
        raise ReleaseError('必须使用 MacGo 自己的 Git 仓库。')
    for marker in ('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply'):
        if Path(git(ROOT, 'rev-parse', '--path-format=absolute', '--git-path', marker)).exists():
            raise ReleaseError(f'Git {marker} 尚未结束，请先处理。')
    public_source_check(ROOT)
    if not publish:
        return
    if git(ROOT, 'branch', '--show-current') != BRANCH:
        raise ReleaseError('标准推送要求 main；不会自动合并或切换分支。')
    if git(ROOT, 'diff', '--cached', '--name-only'):
        raise ReleaseError('已有暂存内容；保留原状，请先处理后再发布，避免混入其他任务。')
    allowed = {f'https://github.com/{REPOSITORY}.git', f'https://github.com/{REPOSITORY}',
               f'git@github.com:{REPOSITORY}.git', f'ssh://git@github.com/{REPOSITORY}.git'}
    for direction in ([], ['--push']):
        urls = git(ROOT, 'remote', 'get-url', *direction, '--all', 'origin').splitlines()
        if len(urls) != 1 or urls[0] not in allowed:
            raise ReleaseError(f'origin 必须只指向 GitHub {REPOSITORY}。')
    command(ROOT, 'git', 'fetch', '--no-tags', 'origin',
            f'refs/heads/{BRANCH}:refs/remotes/origin/{BRANCH}', capture=False)
    if subprocess.run(['git', 'merge-base', '--is-ancestor', f'origin/{BRANCH}', 'HEAD'], cwd=ROOT).returncode:
        raise ReleaseError('远端有尚未纳入的提交；停止推送，不自动重置或变基。')


def validate(run):
    write_json(RECEIPT, {'validated': False, 'reason': 'validation_in_progress'})
    with run.step('检查公开源码、六层规范和脚本'):
        preflight()
        fingerprint = source_fingerprint(ROOT)
        candidate = changed_paths(ROOT)
        command(ROOT, 'git', 'diff', '--check')
        command(ROOT, 'git', 'diff', '--cached', '--check')
        scripts = [str(p.relative_to(ROOT)) for p in sorted((ROOT / 'scripts').glob('*.sh'))]
        for script in ['gogogo.sh', *scripts]:
            command(ROOT, '/bin/bash', '-n', script)
        run.logged('standards.log', '/usr/bin/python3', 'scripts/check-ai.py')
        run.logged('release-tests.log', '/usr/bin/python3', '-m', 'unittest', 'discover',
                   '-s', 'scripts/tests', '-p', 'test_*.py')
    with run.step('运行 Swift 模拟测试，构建并签名应用包'):
        run.logged('swift-tests.log', '/usr/bin/env', 'swift', 'test')
        run.logged('lifecycle-build.log', '/usr/bin/swiftc', 'scripts/app-lifecycle.swift',
                   '-o', str(run.path / 'app-lifecycle'))
        run.logged('build.log', '/bin/bash', 'scripts/build-app.sh')
        assert_stable(fingerprint)
        identity = seal_bundle(ROOT, APP, fingerprint)
    receipt = dict(identity, validated=True, candidate_paths=candidate,
                   validated_at=time.time(), validation_path=str(run.path))
    write_json(RECEIPT, receipt)
    run.evidence['validation'] = receipt
    print(f'验证通过：Mac Go {receipt["version"]} / build {receipt["build"]}；候选回执已保存。', flush=True)
    return receipt


def checked_receipt():
    receipt = read_json(RECEIPT, {})
    if not receipt.get('validated'):
        raise ReleaseError('先运行 ./gogogo.sh 3，获得已验证应用包。')
    assert_stable(receipt['source_fingerprint'])
    if (git(ROOT, 'rev-parse', 'HEAD') != receipt['revision'] or
            directory_fingerprint(APP) != receipt['bundle_fingerprint']):
        raise ReleaseError('Git HEAD 或应用包已改变，请重新验证。')
    command(ROOT, '/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP))
    return receipt


def stage_candidate(root, candidate, fingerprint):
    """Stage only the frozen candidate manifest, never a repository-wide add."""
    if git(root, 'diff', '--cached', '--name-only'):
        raise ReleaseError('验证后出现其他暂存内容，停止提交。')
    if changed_paths(root) != candidate or source_fingerprint(root) != fingerprint:
        raise ReleaseError('提交清单已变化，停止提交。')
    for path in candidate:
        command(root, 'git', 'add', '--all', '--', path)
    if sorted(git_paths(root, 'diff', '--cached', '--name-only')) != candidate:
        raise ReleaseError('暂存文件与验证清单不一致，停止提交。')
    if source_fingerprint(root) != fingerprint:
        raise ReleaseError('暂存期间源码变化，停止提交。')
    return git(root, 'write-tree')


def check_destination(root, destination):
    # Git applies these rules even to literal URL arguments. Do not print
    # replacement keys: a user may have embedded credentials in a rewrite URL.
    result = subprocess.run(['git', 'config', '--null', '--get-regexp',
                             r'^url\..*\.(insteadof|pushinsteadof)$'],
                            cwd=root, capture_output=True)
    if result.returncode not in (0, 1):
        raise ReleaseError('无法核对 Git URL 重写配置，停止推送。')
    for record in result.stdout.split(b'\0'):
        if not record:
            continue
        parts = record.split(b'\n', 1)
        if len(parts) != 2 or not parts[1]:
            raise ReleaseError('无法识别 Git URL 重写配置，停止推送。')
        if destination.startswith(os.fsdecode(parts[1])):
            raise ReleaseError('Git URL 重写可能改变发布目标，停止推送。')


def commit_and_push(run, receipt, default_message):
    with run.step('按已验证文件清单提交'):
        preflight(publish=True)
        checked_receipt()
        base_revision = receipt['revision']
        assert_stable(receipt['source_fingerprint'])
        if receipt['candidate_paths']:
            print('\n'.join(receipt['candidate_paths']), flush=True)
            default = f'chore(release): Mac Go {receipt["version"]} build {receipt["build"]}'
            message = default if default_message else input(f'提交信息 [{default}]：').strip() or default
            if '\n' in message or not message.strip():
                raise ReleaseError('提交信息必须是一行非空文字。')
            tree = stage_candidate(ROOT, receipt['candidate_paths'], receipt['source_fingerprint'])
            command(ROOT, 'git', '-c', 'user.name=al90slj23', '-c',
                    'user.email=5773923+al90slj23@users.noreply.github.com',
                    'commit', '-m', message, capture=False)
            if git(ROOT, 'rev-parse', 'HEAD^{tree}') != tree:
                raise ReleaseError('提交钩子改变源码树，停止推送。')
            parents = git(ROOT, 'rev-list', '--parents', '-n', '1', 'HEAD').split()
            if len(parents) != 2 or parents[1] != base_revision:
                raise ReleaseError('提交历史已改变，停止推送。')
        elif git(ROOT, 'rev-parse', 'HEAD') != base_revision:
            raise ReleaseError('待发布提交已改变，停止推送。')
        assert_stable(receipt['source_fingerprint'])
        if changed_paths(ROOT):
            raise ReleaseError('提交后出现新改动，停止推送。')
        if directory_fingerprint(APP) != receipt['bundle_fingerprint']:
            raise ReleaseError('提交期间应用包改变，停止推送。')
        receipt.update(seal_bundle(ROOT, APP, receipt['source_fingerprint']))
        receipt['candidate_paths'] = []
        write_json(RECEIPT, receipt)
    with run.step('推送 GitHub 并独立核对远端 SHA'):
        preflight(publish=True)
        checked_receipt()
        assert_stable(receipt['source_fingerprint'])
        # Pin the destination argument as well as checking origin; a changed
        # local remote config must never redirect this publication.
        destination = f'https://github.com/{REPOSITORY}.git'
        check_destination(ROOT, destination)
        command(ROOT, 'git', 'push', destination, f'{receipt["revision"]}:refs/heads/{BRANCH}', capture=False)
        remote = git(ROOT, 'ls-remote', '--exit-code', destination, f'refs/heads/{BRANCH}').split()
        if not remote or remote[0] != receipt['revision']:
            raise ReleaseError('GitHub 提交未确认，本机应用尚未更新。')
        run.evidence['github_revision'] = remote[0]
        write_json(run.path / 'github.json', {'repository': REPOSITORY, 'revision': remote[0]})


def verify_runtime(status, expected, since, previous_pid, process_query):
    """A receipt alone is insufficient: verify OS PID owner/path and freshness."""
    pid = status.get('pid', 0)
    if not isinstance(pid, int) or pid <= 1 or pid == previous_pid:
        return False
    expected_path = str(INSTALLED / 'Contents/MacOS/MacGo')
    if status.get('uid') != os.getuid() or status.get('executablePath') != expected_path:
        return False
    try:
        updated = datetime.fromisoformat(status['updatedAt'].replace('Z', '+00:00')).timestamp()
    except (KeyError, TypeError, ValueError):
        return False
    matches = all(status.get(field) == expected[key] for field, key in (
        ('version', 'version'), ('build', 'build'), ('sourceRevision', 'revision'),
        ('sourceFingerprint', 'source_fingerprint'), ('sourceDirty', 'source_dirty')))
    return updated >= since and matches and process_query(pid, expected_path)


def owned_process(pid, executable):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'uid=', '-o', 'comm='],
                            text=True, capture_output=True)
    parts = result.stdout.strip().split(None, 1)
    return result.returncode == 0 and parts == [str(os.getuid()), executable]


def install_validated(run):
    receipt = checked_receipt()
    previous_pid = read_json(RUNTIME, {}).get('pid')
    with run.step('正常退出旧应用、保留回退副本并安装'):
        run.logged('quit.log', '/usr/bin/swift', 'scripts/app-lifecycle.swift', 'quit')
        checked_receipt()
        run.logged('install.log', '/bin/bash', 'scripts/install-local.sh')
        if directory_fingerprint(INSTALLED) != receipt['bundle_fingerprint']:
            raise ReleaseError('安装包与已验证包不一致。旧版保留在安装日志记录的位置。')
    with run.step('启动并核对实际运行的新版本'):
        since = time.time()
        run.logged('launch.log', '/usr/bin/swift', 'scripts/app-lifecycle.swift', 'launch')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            status = read_json(RUNTIME, {})
            if verify_runtime(status, receipt, since, previous_pid, owned_process):
                run.evidence['installed'] = dict(receipt, running=status)
                write_json(run.path / 'installed.json', run.evidence['installed'])
                print(f'本机运行：Mac Go {status["version"]} / build {status["build"]} / PID {status["pid"]}')
                print('权限状态：' + json.dumps({k: status.get(k) for k in (
                    'accessibilityTrusted', 'screenRecordingTrusted', 'fanServiceReady')}, ensure_ascii=False))
                return
            time.sleep(.25)
        raise ReleaseError('应用已安装，但实际运行版本核对未通过；查看本地日志后重试 install。')


def status():
    runtime = read_json(RUNTIME, {})
    alive = owned_process(runtime.get('pid', 0), str(INSTALLED / 'Contents/MacOS/MacGo')) if runtime.get('pid', 0) > 1 else False
    info = bundle_info(INSTALLED) if INSTALLED.exists() else {}
    print(json.dumps({'branch': git(ROOT, 'branch', '--show-current'),
                      'revision': git(ROOT, 'rev-parse', 'HEAD'), 'changes': changed_paths(ROOT),
                      'installed_version': info.get('CFBundleShortVersionString'),
                      'installed_build': info.get('CFBundleVersion'),
                      'running_process_verified': alive, 'running': runtime,
                      'validated': read_json(RECEIPT, {})}, ensure_ascii=False, indent=2))


def usage():
    print('''Mac Go — GitHub 与本机应用更新（无线上部署）
  ./gogogo.sh              交互菜单；非交互仅显示帮助
  ./gogogo.sh 0            检查、构建、正常退出旧版、更新并核对本机运行版本
  ./gogogo.sh 1 1 [d]      检查、按文件清单提交、推送并核对 GitHub、更新本机
                          d 使用默认提交信息；已有暂存内容时停止
  ./gogogo.sh 2            查看源码、安装版、实际进程和权限状态
  ./gogogo.sh 3            仅检查和构建，保存可安装凭据
  ./gogogo.sh install      安装凭据对应的应用包；源码/HEAD/包变化即失效
  ./gogogo.sh plan         只读查看候选文件和固定目标
  ./gogogo.sh ai status    查看 ZERO 检索状态
  ./gogogo.sh ai refresh   刷新 .ai 检索和源码关系''')


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        usage()
        if not sys.stdin.isatty():
            return 0
        args = [(input('\n选择 [2]：').strip() or '2')]
    if args == ['1'] and sys.stdin.isatty():
        print('1) GitHub → 本机应用；0) 返回')
        if input('选择 [1]：').strip() not in ('', '1'):
            return 0
        args = ['1', '1']
    if args == ['2']:
        status(); return 0
    if args == ['plan']:
        preflight()
        print(json.dumps({'repository': REPOSITORY, 'branch': BRANCH,
                          'local_app': str(INSTALLED), 'candidate_paths': changed_paths(ROOT),
                          'source_fingerprint': source_fingerprint(ROOT)}, ensure_ascii=False, indent=2))
        return 0
    if args in (['ai', 'status'], ['ai', 'refresh']):
        command(ROOT, '/bin/bash', '.ai/L0#Execution/workflows/local/retrieval-indexes.sh',
                args[1], capture=False, timeout=3600)
        return 0
    publish = args in (['1', '1'], ['1', '1', 'd'])
    if not publish and args not in (['0'], ['3'], ['install']):
        usage(); return 2
    if publish and len(args) == 2 and not sys.stdin.isatty():
        raise ReleaseError('非交互发布需显式使用 ./gogogo.sh 1 1 d。')
    with release_lock():
        run = Run()
        try:
            preflight(publish=publish)
            receipt = checked_receipt() if args == ['install'] else validate(run)
            if publish:
                commit_and_push(run, receipt, len(args) == 3)
            if args != ['3']:
                install_validated(run)
            run.evidence['status'] = 'passed'
            return 0
        except BaseException:
            run.evidence['status'] = 'failed'
            raise
        finally:
            write_json(run.path / 'result.json', run.evidence)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ReleaseError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'Mac Go 更新已停止：{error}', file=sys.stderr)
        sys.exit(1)
