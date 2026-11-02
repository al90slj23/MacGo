#!/usr/bin/env python3
"""Check native project knowledge navigation and public-source boundaries.

Read-only: does not refresh retrieval, request permissions, or contact hardware.
"""
from pathlib import Path
import json
import re
import sys
from urllib.parse import unquote, urlsplit

from release_support import ReleaseError, public_source_check, visible_paths

ROOT = Path(__file__).resolve().parent.parent
AI = ROOT / '.ai'


def main():
    failures = []
    layers = ('L0#Execution', 'L1#Overview', 'L2#Index', 'L3#Standards', 'L4#Changelog', 'L5#Knowledge')
    for name in layers:
        if not (AI / name).is_dir():
            failures.append(f'Missing layer: {name}')
    checked = 0
    paths = [ROOT / 'README.md', ROOT / 'AGENTS.md', *AI.rglob('*.md')]
    for path in paths:
        if any(part in ('.generated', 'backups') for part in path.relative_to(ROOT).parts):
            continue
        text = re.sub(r'```.*?```', '', path.read_text(), flags=re.S)
        for target in re.findall(r'!?\[[^\]\n]*\]\(([^\s)]+)\)', text):
            if target.startswith(('#', '/', 'http:', 'https:', 'mailto:', 'data:', 'skill:')):
                continue
            parsed = urlsplit(target)
            if parsed.path:
                checked += 1
                if not (path.parent / unquote(parsed.path)).exists():
                    failures.append(f'{path.relative_to(ROOT)}: missing {target}')
    for relative in visible_paths(ROOT):
        path = ROOT / relative
        if (not relative.startswith('.ai/') and path.suffix in ('.py', '.swift', '.sh')
                and path.is_file() and not path.is_symlink()):
            count = len(path.read_text().splitlines())
            if count > 700:
                failures.append(f'Source exceeds 700 lines: {relative} ({count})')
    try:
        public_source_check(ROOT)
    except ReleaseError as error:
        failures.append(str(error))
    print(json.dumps({'layers': len(layers), 'local_links': checked, 'failures': failures},
                     ensure_ascii=False, indent=2))
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
