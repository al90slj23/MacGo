#!/usr/bin/env python3
"""Introduce ZERO templates without replacing project knowledge (Python 3.11+)."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
if sys.version_info < (3, 11):
    sys.exit("ZERO bootstrap requires Python 3.11 or newer.")
import tarfile
import tempfile
import tomllib
from urllib.parse import quote

AI = Path(".ai")
LOCAL = AI / "L0#Execution/workflows/local"
CONFIGS = AI / "L0#Execution/configs"
BACKUPS = AI / "L0#Execution/backups"
FACTS = AI / "L1#Overview/zero-project-facts.md"
GUIDE = AI / "L1#Overview/zero-template-guide.md"
SPEC = AI / "L0#Execution/specs/active/zero-onboarding"
COMPLETED_SPEC = AI / "L0#Execution/specs/completed/zero-onboarding"
ONBOARDING_INDEX = AI / "L2#Index/zero-onboarding.md"
STATE = CONFIGS / "zero-bootstrap-state.json"
CODEX_SOURCE = CONFIGS / "zero-codex.toml"
CODEX_LINK = Path(".codex/config.toml")
VERSION = "2.1.2"


class BootstrapError(Exception):
    pass


def exists(path):
    return os.path.lexists(path)


def check_parents(root, relative):
    """Reject writes through directory aliases, before making a backup or writes."""
    for part in reversed(relative.parents):
        if part == Path("."):
            continue
        path = root / part
        if path.is_symlink() or (exists(path) and not path.is_dir()):
            raise BootstrapError(f"Unsafe parent directory: {path}")


def read_text(path):
    if not exists(path):
        return ""
    if not path.is_file():
        raise BootstrapError(f"Expected a readable file: {path}")
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise BootstrapError(f"Cannot read {path}: {error}") from error


def mode_for(path, default=0o644):
    return stat.S_IMODE(path.stat().st_mode) if path.is_file() else default


def managed(text, begin, end, body):
    """Replace only a complete managed region; preserve all surrounding text."""
    if text.count(begin) != text.count(end) or text.count(begin) > 1:
        raise BootstrapError(f"Malformed managed block: {begin}")
    block = f"{begin}\n{body.rstrip()}\n{end}"
    if begin in text:
        start, finish = text.index(begin), text.index(end) + len(end)
        if start > text.index(end):
            raise BootstrapError(f"Malformed managed block order: {begin}")
        return text[:start] + block + text[finish:]
    return text + ("\n\n" if text and not text.endswith("\n") else "\n" if text else "") + block + "\n"


def template_files(source):
    """Explicit roots exclude inspirations, history, generated stores and backups."""
    fixed = [
        "L0#Execution/README.md", "L0#Execution/workflows/README.md",
        "L0#Execution/skills/README.md", "L0#Execution/templates/README.md",
        "L0#Execution/specs/README.md", "L0#Execution/hooks/README.md",
        "L0#Execution/hooks/retrieval-refresh-on-complete.json",
        "L0#Execution/workflows/local/retrieval-indexes.sh",
        "L0#Execution/workflows/local/retrieval-lock.py",
        "L0#Execution/workflows/local/retrieval-state.py",
        "L0#Execution/workflows/local/zero-bootstrap.py",
        "L0#Execution/workflows/local/zero-bootstrap.sh",
        "L0#Execution/configs/retrieval-toolchain/package.json",
        "L0#Execution/configs/retrieval-toolchain/package-lock.json",
        "L1#Overview/README.md", "L2#Index/README.md", "L2#Index/toc.md",
        "L4#Changelog/README.md", "L5#Knowledge/README.md", "L5#Knowledge/.gitignore",
    ]
    pairs = [(source / AI / name, AI / name) for name in fixed]
    template_guide = source / GUIDE
    if not template_guide.is_file():
        template_guide = source / AI / "L1#Overview/guide.md"
    pairs.append((template_guide, GUIDE))
    for folder in ("L3#Standards/standards", "L3#Standards/references"):
        base = source / AI / folder
        pairs.extend((path, AI / path.relative_to(source / AI))
                     for path in sorted(base.rglob("*.md")))
    for path, _ in pairs:
        if path.is_symlink() or not path.is_file():
            raise BootstrapError(f"Required ZERO template missing or aliased: {path}")
    return pairs


def codex_server(root, action):
    return {"command": "/bin/bash", "args": [str(root / LOCAL / "retrieval-indexes.sh"), action],
            "cwd": str(root), "startup_timeout_sec": 180, "tool_timeout_sec": 180}


def codex_tables(root, names):
    lines = []
    for name, action in (("zero_qmd", "qmd-mcp"), ("zero_codegraph", "codegraph-mcp")):
        if name not in names:
            continue
        lines.append(f"[mcp_servers.{name}]")
        for key, value in codex_server(root, action).items():
            lines.append(f"{key} = {json.dumps(value, ensure_ascii=False)}")
        lines.append("")
    return "\n".join(lines).rstrip()


def parse_toml(text, label):
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise BootstrapError(f"Invalid Codex TOML ({label}): {error}") from error


def merge_codex(root, text):
    begin, end = "# BEGIN ZERO BOOTSTRAP MCP", "# END ZERO BOOTSTRAP MCP"
    if text.count(begin) != text.count(end) or text.count(begin) > 1:
        raise BootstrapError("Malformed ZERO MCP managed block")
    outside = text
    if begin in text:
        start, finish = text.index(begin), text.index(end) + len(end)
        if start > text.index(end):
            raise BootstrapError("Malformed ZERO MCP managed block order")
        old_block = text[start + len(begin):text.index(end)].strip()
        old = parse_toml(old_block, "managed MCP block").get("mcp_servers", {})
        old_root = next(iter(old.values()), {}).get("cwd")
        if not isinstance(old_root, str) or old_block != codex_tables(Path(old_root), set(old)):
            raise BootstrapError("ZERO MCP managed block was customized; reconcile it before bootstrap")
        outside = text[:start] + text[finish:]
    data = parse_toml(outside, str(root / CODEX_LINK))
    servers = data.get("mcp_servers", {})
    if not isinstance(servers, dict):
        raise BootstrapError("Codex mcp_servers must be a table")
    missing = set()
    for name, action in (("zero_qmd", "qmd-mcp"), ("zero_codegraph", "codegraph-mcp")):
        if name in servers and servers[name] != codex_server(root, action):
            raise BootstrapError(f"Existing MCP server '{name}' conflicts; no files were changed")
        if name not in servers:
            missing.add(name)
    result = managed(text, begin, end, codex_tables(root, missing)) if missing else outside
    parse_toml(result, "merged Codex configuration")
    return result


def agent_block(spec):
    return f"""## ZERO project workflow

- Read `{FACTS.as_posix()}` and the project's existing guide first, then `{GUIDE.as_posix()}` and `.ai/L2#Index/toc.md`.
- Project facts and existing project boundaries govern adoption. Read `{ONBOARDING_INDEX.as_posix()}` and reconcile template standards through `{spec.as_posix()}/00.spec-03.tasks.md`; the first introduction remains pending until the Agent completes that audit.
- Maintain source knowledge only in `.ai`. QMD retrieves its Markdown; CodeGraph derives relations from the project's source code. Verify retrieved claims against their owning sources.
- With an exact path/symbol, read the relevant range directly. Unknown document topics start with a scoped QMD lex query (normally 3 results, rerank disabled); code relationships start with a narrow CodeGraph query (normally maxFiles 3). Use vector/expanded search only when needed.
- Reuse current unchanged excerpts still visible in this conversation and treat returned current source as already read. Fetch only missing or stale ranges; normally read 40-80 lines around a document hit and print selected paths/lines/excerpts rather than whole tool objects. Required initial context, audits and complete-file logic reviews still apply.
- If retrieval is unavailable, make at most one targeted retry, then use scoped rg and range reads. Keep the project's owning-source, host and data-boundary verification requirements.
- Batch all `.ai` source Markdown edits and automatically run `bash .ai/L0#Execution/workflows/local/retrieval-indexes.sh refresh` once from the project root at task completion. Read-only tasks and unchanged sources do not proactively refresh; handle failures and reserve explicit repair for a diagnosed stale/broken index.
- Inspect legacy documentation and conventions during onboarding. Business code, API names and database schemas require separately reviewed semantic migrations; bootstrap creates no such migration.
"""


def onboarding_documents(preserved, spec):
    conflicts = "\n".join(f"- `{path}`: existing content preserved; reconcile applicability." for path in preserved)
    facts = """# Project facts — onboarding pending

Record only evidence verified in this project. Read existing project guides and source files before replacing these placeholders.

- Identity, purpose and users: pending audit.
- Runtime, architecture, hosts and data ownership: pending audit.
- Build, verification and deployment entry points: pending audit.
- Existing rules, naming conventions and migration boundaries: pending audit.
- Existing document locations and their canonical owners: pending audit.

Track adoption through the stable navigation `.ai/L2#Index/zero-onboarding.md`.
"""
    documents = {
        FACTS: facts,
        AI / "L1#Overview/guide.md": """# Project Agent entry

Read `zero-project-facts.md` for verified project facts and existing boundaries, then `zero-template-guide.md` for the ZERO template workflow.

Find first introduction tasks through `../L2#Index/zero-onboarding.md` before declaring project adaptation finished. The template does not replace the project's verified facts.
""",
    }
    if spec == COMPLETED_SPEC:
        return documents
    documents.update({
        spec / "00.spec-01.requirements.md": """# ZERO first introduction — requirements

Status: project_adaptation_pending

Adopt ZERO's `.ai` knowledge lifecycle, QMD document retrieval and CodeGraph source relations. Preserve existing project facts, code and configuration. Runtime readiness does not complete project adaptation.
""",
        spec / "00.spec-02.design.md": """# ZERO first introduction — design

Source templates merge without overwriting differing project documents. `.ai` owns policy and generated retrieval state. The root AGENTS managed summary and Codex connection alias point back to `.ai`.

Backups under `.ai/L0#Execution/backups/` contain snapshot.tar and manifest.json; backup trees are excluded from their own snapshots. Existing filesystem contents, modes and symlinks are preserved in the archive.
""",
        spec / "00.spec-03.tasks.md": f"""# ZERO first introduction — Agent adaptation tasks

Status: project_adaptation_pending

- [ ] Audit existing project guides, manifests, source code, data ownership and deployment boundaries; fill `.ai/L1#Overview/zero-project-facts.md` with verified evidence.
- [ ] Inventory old documentation and decide canonical `.ai` destinations. Preserve originals until references and meaning have been verified.
- [ ] Compare existing naming, architecture and code standards with ZERO templates; document retained rules, changes and exceptions in L3/L4.
- [ ] Plan separately any business code/API/table renaming or database migration. Bootstrap does not perform those semantic changes.
- [ ] Reconcile preserved template collisions listed below and update L1/L2 navigation.
- [ ] Run the bootstrap again without `--prepare-only` to initialize retrieval when preparation was requested, then verify both MCP tools in a reloaded trusted client.
- [ ] Run the retrieval adapter `refresh`, record runtime verification and project adaptation separately, then close this onboarding spec when all applicable tasks are complete.

## Preserved differing files

{conflicts or 'No differing template files were found during first introduction.'}
""",
        spec / "00.spec-04.decisions.md": """# ZERO first introduction — decisions

- `.ai` is the canonical knowledge system; indexes are generated and rebuilt from source.
- Existing project facts and rules are preserved for Agent reconciliation. Business code and database migrations require their own evidence, decision and verification.
- `runtime_ready` records tool initialization only. `project_adaptation_pending` remains true until the Agent closes the semantic onboarding tasks.
""",
    })
    return documents


def file_operation(root, relative, content, mode=0o644):
    check_parents(root, relative)
    path = root / relative
    if relative.parts[0] == ".ai" and path.is_symlink():
        raise BootstrapError(f"Managed .ai destination must be a regular file: {path}")
    if exists(path) and not path.is_file():
        raise BootstrapError(f"Expected file at {path}")
    if not path.is_symlink() and path.is_file() and path.read_bytes() == content:
        return None
    return {"path": relative.as_posix(), "content": content, "mode": mode, "kind": "file"}


def onboarding_spec(root):
    active, completed = exists(root / SPEC), exists(root / COMPLETED_SPEC)
    if active and completed:
        raise BootstrapError("ZERO onboarding has both active and completed owners; reconcile before bootstrap")
    spec = COMPLETED_SPEC if completed else SPEC
    check_parents(root, spec / "placeholder")
    return spec


def project_adaptation_pending(root, spec):
    """The onboarding task file is authoritative; JSON records a derived status."""
    tasks = root / spec / "00.spec-03.tasks.md"
    if not tasks.is_file():
        return True
    text = read_text(tasks)
    completed = re.search(r"(?m)^Status:\s*completed\s*$", text)
    unchecked = re.search(r"(?m)^\s*(?:[-*+]|\d+[.)])\s+\[\s\]", text)
    return not completed or bool(unchecked)


def check_runtime_paths(root):
    runtime = AI / "L5#Knowledge/.generated"
    directories = ("tools", "tools/node_modules", "tools/node_modules/.bin", "cache",
                   "cache/npm", "cache/node-gyp", "cache/qmd", "cache/qmd/models",
                   "tmp", "qmd", "qmd/config", "codegraph")
    for name in directories:
        check_parents(root, runtime / name / "placeholder")
    files = ("tools/install.lock", "tools/install-fingerprint", "tools/install-fingerprint.tmp",
             "tools/package.json", "tools/package-lock.json", "qmd/refresh.lock", "qmd/refresh.log",
             "qmd/config/zero.yml", "qmd/config/zero.yml.tmp", "qmd/config/zero.yaml",
             "qmd/config/source-root", "qmd/config/source-root.tmp", "qmd/config/source-model",
             "cache/qmd/zero.sqlite", "cache/qmd/zero.sqlite-wal", "cache/qmd/zero.sqlite-shm",
             "cache/qmd/.qmd-embed.lock", "codegraph-prepare.lock", "codegraph/codegraph.db",
             "codegraph/codegraph.db-wal", "codegraph/codegraph.db-shm")
    for name in files:
        path = root / runtime / name
        if path.is_symlink() or (exists(path) and not path.is_file()):
            raise BootstrapError(f"Unsafe runtime file: {path}")
    # npm executable links are legitimate only when they resolve to a file in
    # this local node_modules. Package-directory aliases can redirect native builds.
    stores = [root / runtime]
    legacy = root / ".codegraph"
    if legacy.is_dir() and not legacy.is_symlink():
        stores.append(legacy)
    npm = root / runtime / "tools/node_modules"
    for store in stores:
        for folder, names, filenames in os.walk(store, followlinks=False):
            for name in names + filenames:
                path = Path(folder) / name
                if path.is_symlink():
                    if (npm in path.parents and path.parent.name == ".bin" and
                            path.resolve().is_relative_to(npm) and path.resolve().is_file()):
                        continue
                    raise BootstrapError(f"Unsafe runtime alias: {path}")
                metadata = path.lstat()
                if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
                    if (path == root / runtime / "codegraph/daemon.sock" and
                            stat.S_ISSOCK(metadata.st_mode) and metadata.st_uid == os.getuid()):
                        continue
                    raise BootstrapError(f"Unsafe runtime special file: {path}")


def plan(source, root, client):
    operations, preserved = [], []
    spec = onboarding_spec(root)
    check_runtime_paths(root)
    essential = {LOCAL / name for name in ("retrieval-indexes.sh", "retrieval-lock.py", "retrieval-state.py", "zero-bootstrap.py", "zero-bootstrap.sh")}
    essential.update({CONFIGS / "retrieval-toolchain/package.json", CONFIGS / "retrieval-toolchain/package-lock.json"})
    for origin, relative in template_files(source):
        check_parents(root, relative)
        target = root / relative
        if exists(target):
            if target.is_symlink() or not target.is_file():
                raise BootstrapError(f"Template destination is not a regular file: {target}")
            if target.read_bytes() != origin.read_bytes():
                if relative in essential:
                    raise BootstrapError(f"Required runtime file differs; reconcile without overwriting: {target}")
                preserved.append(relative.as_posix())
            continue
        operations.append({"path": relative.as_posix(), "content": origin.read_bytes(),
                           "mode": stat.S_IMODE(origin.stat().st_mode), "kind": "file"})
    for relative, content in onboarding_documents(preserved, spec).items():
        check_parents(root, relative)
        if not exists(root / relative):
            operations.append({"path": relative.as_posix(), "content": content.encode(), "mode": 0o644, "kind": "file"})
        elif not (root / relative).is_file() or (root / relative).is_symlink():
            raise BootstrapError(f"Onboarding destination is not a regular file: {root / relative}")
    for relative, begin, end, body in [
        (Path("AGENTS.md"), "<!-- BEGIN ZERO BOOTSTRAP -->", "<!-- END ZERO BOOTSTRAP -->", agent_block(spec)),
        (Path(".gitignore"), "# BEGIN ZERO BOOTSTRAP", "# END ZERO BOOTSTRAP",
         "/.ai/L5#Knowledge/.generated/\n/.ai/L0#Execution/backups/\n/.codegraph"),
        (ONBOARDING_INDEX, "<!-- BEGIN ZERO ONBOARDING NAVIGATION -->", "<!-- END ZERO ONBOARDING NAVIGATION -->",
         f"# ZERO onboarding navigation\n\n[Authoritative adaptation tasks](../{quote(spec.relative_to(AI).as_posix(), safe='/')}/00.spec-03.tasks.md).\n\nThis index only routes to the current owner; completion is derived from that task file."),
    ]:
        content = managed(read_text(root / relative), begin, end, body).encode()
        op = file_operation(root, relative, content, mode_for(root / relative))
        if op: operations.append(op)
    if client == "codex":
        check_parents(root, CODEX_LINK)
        check_parents(root, CODEX_SOURCE)
        connection, owned = root / CODEX_LINK, root / CODEX_SOURCE
        connection_text, owned_text = read_text(connection), read_text(owned)
        if exists(connection) and exists(owned) and connection_text != owned_text:
            raise BootstrapError("Existing Codex connection and .ai config source differ; reconcile them first")
        text = merge_codex(root, connection_text if exists(connection) else owned_text)
        if owned.is_symlink():
            raise BootstrapError(f"Codex .ai source must be a regular file: {owned}")
        op = file_operation(root, CODEX_SOURCE, text.encode(), mode_for(connection, 0o600))
        if op: operations.append(op)
        link = os.path.relpath(root / CODEX_SOURCE, connection.parent)
        if not connection.is_symlink() or os.readlink(connection) != link:
            operations.append({"path": CODEX_LINK.as_posix(), "target": link, "kind": "symlink"})
    previous = {}
    if exists(root / STATE):
        try: previous = json.loads(read_text(root / STATE))
        except (ValueError, TypeError) as error: raise BootstrapError(f"Invalid bootstrap state: {error}") from error
        if not isinstance(previous, dict):
            raise BootstrapError("Bootstrap state must be a JSON object")
        for key in ("runtime_ready", "project_adaptation_pending"):
            if key in previous and not isinstance(previous[key], bool):
                raise BootstrapError(f"Bootstrap state '{key}' must be a boolean")
    state = {"zero_version": VERSION, "client": client,
             "runtime_ready": previous.get("runtime_ready", False),
             "project_adaptation_pending": project_adaptation_pending(root, spec)}
    op = file_operation(root, STATE, (json.dumps(state, ensure_ascii=False, indent=2) + "\n").encode())
    if op: operations.append(op)
    check_parents(root, BACKUPS / "placeholder")
    alias, store = root / ".codegraph", root / AI / "L5#Knowledge/.generated/codegraph"
    if alias.is_symlink() and os.readlink(alias) != ".ai/L5#Knowledge/.generated/codegraph":
        raise BootstrapError("Existing .codegraph alias has another target")
    if exists(alias) and not alias.is_symlink() and (not alias.is_dir() or exists(store)):
        raise BootstrapError("Existing .codegraph store cannot be migrated safely")
    return operations, preserved, state


def snapshot_entry(root, relative):
    path = root / relative
    entry = {"path": relative.as_posix(), "existed": exists(path)}
    if exists(path):
        entry["mode"] = stat.S_IMODE(path.lstat().st_mode)
        entry["kind"] = "symlink" if path.is_symlink() else "directory" if path.is_dir() else "file"
        if path.is_symlink(): entry["target"] = os.readlink(path)
    return entry


def backup(root, operations, initialize_runtime=False):
    watched = [AI, Path("AGENTS.md"), Path(".gitignore"), CODEX_LINK, Path(".codegraph")]
    before = [snapshot_entry(root, path) for path in watched]
    legacy_store = root / ".codegraph"
    migrates_legacy = initialize_runtime and legacy_store.is_dir() and not legacy_store.is_symlink()
    if (not operations and not migrates_legacy) or not any(entry["existed"] for entry in before):
        return None
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    folder = root / BACKUPS / ("zero-bootstrap-" + stamp)
    created_parents = {str(path.relative_to(root)) for path in folder.parents
                       if path != root and root in path.parents and not exists(path)}
    folder.mkdir(parents=True, mode=0o700, exist_ok=False)
    def exclude_backups(info):
        excluded = info.name in created_parents or info.name == BACKUPS.as_posix() or info.name.startswith(BACKUPS.as_posix() + "/")
        return None if excluded else info
    with tarfile.open(folder / "snapshot.tar", "w") as archive:
        codex_folder = root / ".codex"
        if codex_folder.is_dir() and not codex_folder.is_symlink():
            archive.add(codex_folder, arcname=".codex", recursive=False)
        for entry in before:
            if entry["existed"]:
                archive.add(root / entry["path"], arcname=entry["path"], filter=exclude_backups)
                path = root / entry["path"]
                if path.is_symlink() and path.is_file():
                    resolved_name = "resolved-links/" + entry["path"]
                    archive.add(path.resolve(), arcname=resolved_name, recursive=False)
                    entry["resolved_snapshot"] = resolved_name
    (folder / "snapshot.tar").chmod(0o600)
    manifest = {"format": "zero-bootstrap-backup-v1", "target": str(root), "entries": before,
                "excluded": [BACKUPS.as_posix()], "created_backup_parent_directories": sorted(created_parents),
                "archive": "snapshot.tar"}
    (folder / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (folder / "manifest.json").chmod(0o600)
    return folder


def apply_operations(root, operations):
    for op in operations:
        path = root / op["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".zero-bootstrap-", dir=path.parent)
        os.close(fd)
        try:
            if op["kind"] == "symlink":
                os.unlink(temporary)
                os.symlink(op["target"], temporary)
            else:
                Path(temporary).write_bytes(op["content"])
                os.chmod(temporary, op["mode"])
            os.replace(temporary, path)
        finally:
            if os.path.lexists(temporary): os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=Path, default=Path.cwd())
    parser.add_argument("--client", choices=("codex", "none"), default="codex")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[4]
    root = args.target.expanduser().resolve()
    if root == Path(root.anchor) or root == Path.home().resolve():
        raise BootstrapError("Choose a project directory; filesystem root and home are not valid targets")
    if exists(root) and not root.is_dir(): raise BootstrapError(f"Target is not a directory: {root}")
    operations, preserved, state = plan(source, root, args.client)
    root.mkdir(parents=True, exist_ok=True)
    saved = backup(root, operations, initialize_runtime=not args.prepare_only)
    apply_operations(root, operations)
    if not args.prepare_only:
        result = subprocess.run(["/bin/bash", str(root / LOCAL / "retrieval-indexes.sh"), "init"],
                                cwd=root, stdout=sys.stderr, check=False)
        if result.returncode:
            state["runtime_ready"] = False
            apply_operations(root, [{"path": STATE.as_posix(), "content": (json.dumps(state, indent=2) + "\n").encode(), "mode": 0o644, "kind": "file"}])
            raise BootstrapError(f"Retrieval init failed (exit {result.returncode}); onboarding remains pending. Backup: {saved}")
        state["runtime_ready"] = True
        apply_operations(root, [{"path": STATE.as_posix(), "content": (json.dumps(state, indent=2) + "\n").encode(), "mode": 0o644, "kind": "file"}])
    print(json.dumps({"target": str(root), "mode": "prepare_only" if args.prepare_only else "runtime_initialized",
                      "runtime_verified_this_run": not args.prepare_only,
                      "changed_files": len(operations), "backup": str(saved) if saved else None,
                      "preserved_differing_templates": preserved, **state}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BootstrapError, OSError, ValueError) as error:
        print(f"ZERO bootstrap failed: {error}", file=sys.stderr)
        sys.exit(1)
