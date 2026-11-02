#!/usr/bin/env python3
"""Run a retrieval maintenance command under a POSIX advisory file lock.

The lock file persists; the kernel releases the lock when its owners exit.
Background workers detach and redirect all standard streams before returning.
"""
import argparse
import errno
import fcntl
import os
import pathlib
import subprocess
import sys


def open_owned_file(path, mode):
    """Reject aliases before creating lock/log state, including the final inode."""
    path = pathlib.Path(path).absolute()
    for component in (path.parent, *path.parent.parents):
        if component.is_symlink() or (component.exists() and not component.is_dir()):
            raise OSError(f"Retrieval state parent must be a real directory: {component}")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_CREAT | os.O_APPEND | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    return os.fdopen(descriptor, mode, buffering=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--nonblocking", action="store_true")
    parser.add_argument("--background", action="store_true")
    parser.add_argument("--log")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    if args.background:
        if not args.log:
            parser.error("--background requires --log")
        log_path = pathlib.Path(args.log)
        worker = [sys.executable, os.path.abspath(__file__), "--lock", args.lock]
        if args.nonblocking:
            worker.append("--nonblocking")
        worker.extend(["--", *command])
        with open_owned_file(log_path, "a") as log:
            subprocess.Popen(worker, stdin=subprocess.DEVNULL, stdout=log,
                             stderr=subprocess.STDOUT, start_new_session=True,
                             close_fds=True)
        return 0

    lock_path = pathlib.Path(args.lock)
    # Never unlink this file: replacing its inode would allow two lock owners.
    with open_owned_file(lock_path, "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | (fcntl.LOCK_NB if args.nonblocking else 0))
        except OSError as error:
            if args.nonblocking and error.errno in (errno.EACCES, errno.EAGAIN):
                print("QMD refresh already running; using the existing index.", file=sys.stderr)
                return 0
            raise
        # The child also inherits this descriptor, so an interrupted wrapper
        # cannot release the lock while its maintenance command is still alive.
        print("Retrieval maintenance started.", file=sys.stderr, flush=True)
        result = subprocess.run(command, pass_fds=(lock.fileno(),), check=False)
        if result.returncode:
            print(f"Retrieval maintenance failed (exit {result.returncode}).", file=sys.stderr)
        else:
            print("Retrieval maintenance completed.", file=sys.stderr)
        return result.returncode if result.returncode >= 0 else 128 - result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError as error:
        print(f"Retrieval lock helper failed: {error}", file=sys.stderr)
        sys.exit(1)
