#!/usr/bin/env python3
"""Validate reusable retrieval results. Called under the adapter's writer locks.

Only successful, stable source snapshots receive a checkpoint. This helper does
not install tools, load models, open a writable SQLite connection, or start IPC.
The embedding format below is tied to the pinned QMD 2.8.3 Qwen configuration.
"""

import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import sys


ROOT = Path(sys.argv[2]).resolve()
RUNTIME = ROOT / '.ai/L5#Knowledge/.generated'
ADAPTER = Path(sys.argv[3])
MODEL = os.environ['QMD_EMBED_MODEL']
QMD_IGNORED = {'node_modules', 'vendor', 'dist', 'build', '.git', '.cache'}
GRAPH_IGNORED = QMD_IGNORED | {'.ai', '.codegraph', 'coverage'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_digest(value):
    return sha(json.dumps(value, ensure_ascii=False, sort_keys=True).encode())


def visible_paths(base, ignored):
    if not base.is_dir() or base.is_symlink():
        return
    for directory, folders, files in os.walk(base, followlinks=False):
        folders[:] = sorted(name for name in folders if not name.startswith('.')
                            and name not in ignored
                            and not (Path(directory) / name).is_symlink())
        for name in sorted(files):
            path = Path(directory) / name
            if not name.startswith('.') and not path.is_symlink() and path.is_file():
                yield path


def qmd_sources():
    result = {}
    ai = ROOT / '.ai'
    for layer in ('L0#Execution', 'L1#Overview', 'L2#Index', 'L3#Standards', 'L4#Changelog'):
        for path in visible_paths(ai / layer, QMD_IGNORED):
            relative = path.relative_to(ai)
            if (relative.parts[:2] == ('L0#Execution', 'backups')
                    or path.suffix != '.md'):
                continue
            text = path.read_bytes().decode('utf-8', errors='replace')
            if text.strip():
                result[relative.as_posix()] = sha(text.encode())
    readme = ai / 'L5#Knowledge/README.md'
    if readme.is_file() and not readme.is_symlink():
        text = readme.read_bytes().decode('utf-8', errors='replace')
        if text.strip():
            result[readme.relative_to(ai).as_posix()] = sha(text.encode())
    return result


def implementation():
    return {
        'adapter': sha(ADAPTER.read_bytes()),
        'state_helper': sha(Path(__file__).read_bytes()),
        'tools': (RUNTIME / 'tools/install-fingerprint').read_text().strip(),
    }


def qmd_snapshot():
    manifest = RUNTIME / 'qmd/models-manifest.json'
    return {
        'version': 1, 'implementation': implementation(), 'sources': qmd_sources(),
        'config': json.loads((RUNTIME / 'qmd/config/zero.yml').read_text()),
        # The explicit init path verifies these large files. Common reads never
        # rehash GGUFs; reuse its successful manifest rather than opening models.
        'models_manifest': sha(manifest.read_bytes()) if manifest.exists() else None,
    }


def readonly_db(path):
    # URI quoting matters: the canonical .ai path contains a literal '#'.
    return sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)


def qmd_healthy(snapshot):
    significant = '\n'.join((
        f'model:{MODEL}',
        'query:Instruct: Retrieve relevant documents for the given query\nQuery: __qmd_embedding_query_probe__',
        'doc:__qmd_embedding_title_probe__\n__qmd_embedding_document_probe__',
        'chunk_tokens:900', 'chunk_overlap_tokens:135',
    ))
    fingerprint = sha(significant.encode())[:6]
    with readonly_db(RUNTIME / 'cache/qmd/zero.sqlite') as connection:
        actual = dict(connection.execute(
            "SELECT path, hash FROM documents WHERE active=1 AND collection='zero-ai'"))
        if actual != snapshot['sources']:
            return False
        # Upstream embed can exit zero after reporting per-document errors.
        # Verify every active hash has all chunks for the current model format.
        pending = connection.execute('''
            SELECT COUNT(*) FROM documents d LEFT JOIN (
                SELECT hash, COUNT(*) AS chunks, MAX(total_chunks) AS expected
                FROM content_vectors WHERE model=? AND embed_fingerprint=? GROUP BY hash
            ) v ON d.hash=v.hash
            WHERE d.active=1 AND d.collection='zero-ai'
              AND (v.hash IS NULL OR v.expected IS NULL OR v.expected<1 OR v.chunks<v.expected)
        ''', (MODEL, fingerprint)).fetchone()[0]
        return pending == 0


def graph_sources():
    try:
        tracked = subprocess.run(
            ['git', '-C', str(ROOT), 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
            check=True, capture_output=True,
        ).stdout
        candidates = (ROOT / os.fsdecode(name) for name in tracked.split(b'\0') if name)
    except (OSError, subprocess.CalledProcessError):
        candidates = visible_paths(ROOT, GRAPH_IGNORED)
    result = {}
    for path in candidates:
        relative = path.relative_to(ROOT)
        if any(part.startswith('.') or part in GRAPH_IGNORED for part in relative.parts):
            continue
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents if parent != ROOT):
            continue
        if path.is_file():
            result[relative.as_posix()] = sha(path.read_bytes())
    return result


def graph_version():
    package = RUNTIME / 'tools/node_modules/@colbymchenry/codegraph/package.json'
    return json.loads(package.read_text())['version']


def graph_database():
    database = RUNTIME / 'codegraph/codegraph.db'
    metadata = database.stat()
    with readonly_db(database) as connection:
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not {'files', 'nodes', 'schema_versions', 'project_metadata'} <= tables:
            raise ValueError('CodeGraph schema is incomplete')
        versions = connection.execute('SELECT MAX(version) FROM schema_versions').fetchone()[0]
        values = dict(connection.execute('SELECT key,value FROM project_metadata'))
        if (versions is None or versions < 11 or values.get('index_state') != 'complete'
                or values.get('indexed_with_version') != graph_version()):
            raise ValueError('CodeGraph schema or indexed version is not ready')
        # Query the actual graph tables as well as their schema names.
        connection.execute('SELECT 1 FROM files LIMIT 1').fetchone()
        connection.execute('SELECT 1 FROM nodes LIMIT 1').fetchone()
    return {'device': metadata.st_dev, 'inode': metadata.st_ino}


def active_graph_daemon():
    store = RUNTIME / 'codegraph'
    metadata = (store / 'daemon.sock').lstat()
    if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid():
        return False
    daemon = json.loads((store / 'daemon.pid').read_text())
    writer = json.loads((store / 'writer.pid').read_text())
    if (type(daemon.get('pid')) is not int or daemon['pid'] <= 1
            or daemon['pid'] != writer['pid'] or writer.get('mode') != 'daemon'
            or not writer.get('ready') or daemon.get('version') != graph_version()
            or Path(daemon.get('socketPath', '')).resolve() != store / 'daemon.sock'):
        return False
    os.kill(daemon['pid'], 0)
    return True


def graph_snapshot():
    return {'version': 1, 'implementation': implementation(), 'sources': graph_sources()}


def write_marker(path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True) + '\n')
    os.replace(temporary, path)


def main():
    action = sys.argv[1]
    if action.startswith('qmd-'):
        marker = RUNTIME / 'qmd/refresh-success.json'
        snapshot = qmd_snapshot()
        digest = json_digest(snapshot)
        if action == 'qmd-fingerprint':
            print(digest)
        elif action == 'qmd-reusable':
            checkpoint = json.loads(marker.read_text())
            if checkpoint.get('fingerprint') != digest or not qmd_healthy(snapshot):
                return 1
        elif action == 'qmd-record':
            if sys.argv[4] != digest or not qmd_healthy(snapshot):
                return 1
            write_marker(marker, {'version': 1, 'fingerprint': digest, 'documents': len(snapshot['sources'])})
        else:
            return 2
    elif action == 'graph-fingerprint':
        print(json_digest(graph_snapshot()))
    elif action == 'graph-adopt':
        # Upgrades may lack our checkpoint while the official shared writer is
        # already healthy. Do not compete with that daemon for its SQLite lock.
        for _attempt in range(3):
            database = graph_database()
            if not active_graph_daemon():
                return 1
            snapshot = graph_snapshot()
            digest = json_digest(snapshot)
            if digest != json_digest(graph_snapshot()):
                continue
            if graph_database() != database or not active_graph_daemon():
                return 1
            write_marker(RUNTIME / 'codegraph-prepared.json', {
                'version': 1, 'fingerprint': digest,
                'implementation': snapshot['implementation'], 'database': database,
            })
            return 0
        print('CodeGraph sources are still changing; shared daemon adoption remains pending.', file=sys.stderr)
        return 75
    elif action == 'graph-reusable':
        checkpoint = json.loads((RUNTIME / 'codegraph-prepared.json').read_text())
        if (checkpoint.get('database') != graph_database()
                or checkpoint.get('implementation') != implementation()):
            return 1
        try:
            if active_graph_daemon():
                return 0
        except (OSError, ValueError, KeyError):
            pass
        if checkpoint.get('fingerprint') != json_digest(graph_snapshot()):
            return 1
    elif action == 'graph-record':
        digest = json_digest(graph_snapshot())
        if sys.argv[4] != digest:
            return 1
        write_marker(RUNTIME / 'codegraph-prepared.json', {
            'version': 1, 'fingerprint': digest, 'implementation': implementation(),
            'database': graph_database(),
        })
    else:
        return 2
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, sqlite3.Error):
        # A missing checkpoint, incomplete store, or source race is never a hit.
        sys.exit(1)
