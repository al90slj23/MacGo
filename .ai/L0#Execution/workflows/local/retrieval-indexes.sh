#!/usr/bin/env bash
# 文件职责：自动构建/刷新 .ai 内的 QMD 文档索引和 CodeGraph 源码图。
# 核心架构：源资料只维护一份；配置、索引、模型缓存由本适配器生成。
# 主要函数：setup_tools、qmd_command、prepare_qmd、refresh_qmd、prepare_codegraph。
# 依赖关系：Bash、Python3、Node.js >= 22、npm；CLI 自动安装在 .ai 内。
set -euo pipefail

usage() {
    printf 'Usage: bash %s <setup|init|refresh|refresh-force|status|qmd-mcp|codegraph-mcp|qmd [args...]>\n' "$0" >&2
}
[[ $# -ge 1 ]] || { usage; exit 2; }
action="$1"
shift
case "$action" in
    setup|refresh|refresh-force|init|status|qmd-mcp|codegraph-mcp|tools-prepare-without-lock|qmd-init-without-lock|qmd-prepare|qmd-refresh-without-lock|qmd-force-without-lock|codegraph-prepare-without-lock|codegraph-force-without-lock) [[ $# -eq 0 ]] || { usage; exit 2; } ;;
    qmd)
        [[ $# -ge 1 ]] || { usage; exit 2; }
        case "$1" in
            search|vsearch|query|get|multi-get|ls|status) ;;
            *) printf 'Only document retrieval commands are exposed by this adapter.\n' >&2; exit 2 ;;
        esac
        for argument in "$@"; do
            case "$argument" in
                --index|--index=*) printf 'The adapter owns index selection.\n' >&2; exit 2 ;;
            esac
        done
        ;;
    *) usage; exit 2 ;;
esac
[[ -d .ai/L1#Overview && -d .ai/L3#Standards ]] || {
    printf 'Run from the target project root containing .ai/.\n' >&2
    exit 2
}
project_root="$(pwd -P)"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
script_path="$script_dir/$(basename -- "${BASH_SOURCE[0]}")"
lock_helper="$script_dir/retrieval-lock.py"
state_helper="$script_dir/retrieval-state.py"
runtime="$project_root/.ai/L5#Knowledge/.generated"
qmd_config="$runtime/qmd/config"
qmd_database="$runtime/cache/qmd/zero.sqlite"
toolchain="$project_root/.ai/L0#Execution/configs/retrieval-toolchain"
export PATH="$runtime/tools/node_modules/.bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
    export PATH="$PATH:/opt/homebrew/bin"
fi
export QMD_EMBED_MODEL='hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf'
export QMD_RERANK_MODEL='hf:ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf'
export QMD_GENERATE_MODEL='hf:tobil/qmd-query-expansion-1.7B-gguf/qmd-query-expansion-1.7B-q4_k_m.gguf'
export QMD_EMBED_PARALLELISM=1
codegraph_data="$runtime/codegraph"
codegraph_alias='.ai/L5#Knowledge/.generated/codegraph'
# Named QMD index bypasses parent .qmd discovery; all stores remain inside .ai.
export QMD_CONFIG_DIR="$qmd_config"
export XDG_CACHE_HOME="$runtime/cache"
unset INDEX_PATH
# CodeGraph only accepts one root directory segment, so use an automatic alias.
export CODEGRAPH_DIR=.codegraph
export CODEGRAPH_TELEMETRY=0
export DO_NOT_TRACK=1
# Shared daemon supports multiple clients; its process registry is automatic.
unset CODEGRAPH_NO_DAEMON

require_cli() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '%s is unavailable; source documents remain usable. See the retrieval standard.\n' "$1" >&2
        return 1
    }
}

preflight_owned_paths() {
    # Check before acquiring locks, installing packages, or opening databases.
    # npm executable links are allowed only inside this project's real modules.
    python3 - "$project_root" <<'PY'
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
runtime = root / '.ai/L5#Knowledge/.generated'
modules = runtime / 'tools/node_modules'
owned_dirs = (
    '.ai', '.ai/L5#Knowledge', '.ai/L5#Knowledge/.generated',
    'tools', 'tools/node_modules', 'tools/node_modules/.bin',
    'cache', 'cache/npm', 'cache/node-gyp', 'cache/qmd', 'cache/qmd/models',
    'tmp', 'qmd', 'qmd/config', 'codegraph',
)
def refuse(path):
    raise SystemExit(f'Retrieval preflight refused an aliased or invalid owned path: {path}')

for relative in owned_dirs:
    path = root / relative if relative.startswith('.ai') else runtime / relative
    for component in (path, *path.parents):
        if component == root:
            break
        if component.is_symlink() or (component.exists() and not component.is_dir()):
            refuse(component)

alias = root / '.codegraph'
legacy = None
if alias.is_symlink():
    if os.readlink(alias) != '.ai/L5#Knowledge/.generated/codegraph':
        refuse(alias)
elif alias.exists():
    if not alias.is_dir() or (runtime / 'codegraph').exists():
        refuse(alias)
    legacy = alias

def scan(store):
    def onerror(error):
        raise error
    for parent, directories, files in os.walk(store, followlinks=False, onerror=onerror):
        for name in directories + files:
            path = pathlib.Path(parent) / name
            if path.is_symlink():
                if modules in path.parents and path.parent.name == '.bin':
                    try:
                        destination = path.resolve(strict=True)
                        destination.relative_to(modules)
                        if destination.is_file():
                            continue
                    except (OSError, ValueError, RuntimeError):
                        pass
                refuse(path)
            if path.exists() and not (path.is_dir() or path.is_file()):
                # CodeGraph's shared daemon owns this one local IPC socket.
                # Preserve a running daemon; other special files stay rejected.
                metadata = path.lstat()
                if (path == runtime / 'codegraph/daemon.sock'
                        and stat.S_ISSOCK(metadata.st_mode)
                        and metadata.st_uid == os.getuid()):
                    continue
                refuse(path)

try:
    if runtime.exists():
        scan(runtime)
    if legacy is not None:
        scan(legacy)
except OSError as error:
    raise SystemExit(f'Retrieval preflight could not inspect owned state: {error}')
PY
}

toolchain_fingerprint() {
    local node_runtime
    node_runtime="$(node -p 'JSON.stringify([process.versions.node, process.versions.modules, process.platform, process.arch])')" || return 1
    python3 - "$toolchain" "$node_runtime" <<'PY'
import hashlib
import pathlib
import sys
source = pathlib.Path(sys.argv[1])
digest = hashlib.sha256(sys.argv[2].encode())
for name in ('package.json', 'package-lock.json'):
    digest.update((source / name).read_bytes())
print(digest.hexdigest())
PY
}

tools_ready() {
    [[ -x "$runtime/tools/node_modules/.bin/qmd" && -x "$runtime/tools/node_modules/.bin/codegraph" && -s "$runtime/tools/install-fingerprint" ]] || return 1
    [[ "$(cat "$runtime/tools/install-fingerprint")" == "$(toolchain_fingerprint)" ]] || return 1
    python3 - "$toolchain/package.json" "$runtime/tools/node_modules" <<'PY'
import json
import pathlib
import sys
try:
    expected = json.loads(pathlib.Path(sys.argv[1]).read_text())['dependencies']
    modules = pathlib.Path(sys.argv[2])
    for name, version in expected.items():
        if json.loads((modules / name / 'package.json').read_text())['version'] != version:
            sys.exit(1)
except (OSError, ValueError, KeyError):
    sys.exit(1)
PY
}

setup_tools_without_lock() {
    require_cli node || return 1
    require_cli npm || return 1
    node -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("Retrieval requires Node.js >= 22."); process.exit(1); }' || return 1
    [[ -s "$toolchain/package.json" && -s "$toolchain/package-lock.json" ]] || {
        printf 'Missing .ai retrieval toolchain manifest or lockfile.\n' >&2
        return 1
    }
    tools_ready && return 0
    mkdir -p "$runtime/tools" "$runtime/cache/npm" "$runtime/cache/node-gyp" "$runtime/tmp" || return 1
    # A failed install must never leave a successful bootstrap marker behind.
    rm -f "$runtime/tools/install-fingerprint" || return 1
    cp "$toolchain/package.json" "$toolchain/package-lock.json" "$runtime/tools/" || return 1
    npm_config_devdir="$runtime/cache/node-gyp" TMPDIR="$runtime/tmp" npm --registry=https://registry.npmjs.org --prefix "$runtime/tools" --cache "$runtime/cache/npm" ci --no-audit --no-fund || return 1
    toolchain_fingerprint > "$runtime/tools/install-fingerprint.tmp" || return 1
    mv "$runtime/tools/install-fingerprint.tmp" "$runtime/tools/install-fingerprint" || return 1
    if ! tools_ready; then
        rm -f "$runtime/tools/install-fingerprint"
        printf 'Retrieval installation did not produce the pinned local CLIs.\n' >&2
        return 1
    fi
}

setup_tools() {
    require_cli python3 || return 1
    # Installation is shared by all startup/refresh callers, including first use.
    python3 "$lock_helper" --lock "$runtime/tools/install.lock" -- /bin/bash "$script_path" tools-prepare-without-lock
}

qmd_command() { qmd --index zero "$@"; }
retrieval_state() { python3 "$state_helper" "$1" "$project_root" "$script_path" "${2:-}"; }

write_qmd_config() {
    # JSON is valid YAML. Generate the complete owned config so persisted model
    # defaults can never override the Chinese embedding model on later queries.
    python3 - "$qmd_config/zero.yml.tmp" "$project_root/.ai" "$QMD_EMBED_MODEL" "$QMD_RERANK_MODEL" "$QMD_GENERATE_MODEL" "${1:-write}" <<'PY'
import json
import pathlib
import sys
config = {
    'models': {
        'embed': sys.argv[3],
        'rerank': sys.argv[4],
        'generate': sys.argv[5],
    },
    'collections': {
        'zero-ai': {
            'path': sys.argv[2],
            'pattern': 'L0#Execution/**/*.md,L1#Overview/**/*.md,L2#Index/**/*.md,L3#Standards/**/*.md,L4#Changelog/**/*.md,L5#Knowledge/README.md',
            'ignore': ['L0#Execution/backups/**', '**/.generated/**'],
        },
    },
}
temporary = pathlib.Path(sys.argv[1])
if sys.argv[6] == 'verify':
    source = temporary.with_name('zero.yml')
    if not source.exists():
        source = source.with_name('zero.yaml')
    try:
        sys.exit(0 if json.loads(source.read_text()) == config else 1)
    except (OSError, ValueError):
        # Older generated YAML is normalized without changing its model marker.
        sys.exit(1)
else:
    temporary.write_text(json.dumps(config, ensure_ascii=False, indent=2) + '\n')
PY
}

qmd_ready() {
    [[ -s "$qmd_config/source-root" && "$(cat "$qmd_config/source-root")" == "$project_root" ]] &&
        [[ -s "$qmd_config/zero.yml" || -s "$qmd_config/zero.yaml" ]] &&
        [[ -s "$qmd_database" && -s "$qmd_config/source-model" && "$(cat "$qmd_config/source-model")" == "$QMD_EMBED_MODEL" ]] &&
        write_qmd_config verify
}

qmd_locked() {
    require_cli python3 || return 1
    python3 "$lock_helper" --lock "$runtime/qmd/refresh.lock" -- /bin/bash "$script_path" "$1"
}

# Called only while holding the project refresh lock. A missing/moved store is
# rebuilt from the generated collection config, including its searchable text DB.
prepare_qmd_without_lock() {
    qmd_ready && return 0
    mkdir -p "$qmd_config" || return 1
    rm -f "$runtime/qmd/refresh-success.json" || return 1
    # Existing vectors from another/unknown model need dimension-safe rebuilding.
    if [[ -s "$qmd_database" && ( ! -s "$qmd_config/source-model" || "$(cat "$qmd_config/source-model")" != "$QMD_EMBED_MODEL" ) ]]; then
        touch "$qmd_config/reembed-required" || return 1
    fi
    write_qmd_config || return 1
    mv "$qmd_config/zero.yml.tmp" "$qmd_config/zero.yml" || return 1
    rm -f "$qmd_config/zero.yaml" "$qmd_config/source-root" || return 1
    qmd_command update || return 1
    [[ -s "$qmd_database" ]] || { printf 'QMD text database was not created.\n' >&2; return 1; }
    printf '%s\n' "$project_root" > "$qmd_config/source-root.tmp" || return 1
    mv "$qmd_config/source-root.tmp" "$qmd_config/source-root" || return 1
    printf '%s\n' "$QMD_EMBED_MODEL" > "$qmd_config/source-model"
}

prepare_qmd() {
    require_cli qmd || return 1
    # Existing MCP clients must not wait behind a long-running embed.
    qmd_ready || qmd_locked qmd-prepare
}

refresh_qmd_without_lock() {
    local force="${1:-}" before after attempt
    require_cli qmd || return 1
    prepare_qmd_without_lock || return 1
    # Recheck after taking the lock: a waiting caller reuses the completed work.
    if [[ -z "$force" && ! -f "$qmd_config/reembed-required" ]] && retrieval_state qmd-reusable; then
        printf 'QMD source and complete index unchanged; reusing successful refresh.\n' >&2
        return 0
    fi
    rm -f "$runtime/qmd/refresh-success.json" || return 1
    for attempt in 1 2 3; do
        before="$(retrieval_state qmd-fingerprint)" || return 1
        qmd_command update || return 1
        if [[ -n "$force" || -f "$qmd_config/reembed-required" ]]; then
            qmd_command embed --timeout 0 -f || return 1
            rm -f "$qmd_config/reembed-required" || return 1
        else
            qmd_command embed --timeout 0 || return 1
        fi
        after="$(retrieval_state qmd-fingerprint)" || return 1
        if [[ "$before" == "$after" ]]; then
            if retrieval_state qmd-record "$before"; then return 0; fi
            printf 'QMD returned without complete current document/vector coverage; refresh remains pending.\n' >&2
            return 1
        fi
        printf 'QMD sources changed during refresh; checking the newer snapshot (%s/3).\n' "$attempt" >&2
        # The initial forced rebuild is already complete; subsequent passes are incremental.
        force=''
    done
    printf 'QMD sources are still changing; no successful refresh checkpoint recorded.\n' >&2
    return 1
}

refresh_qmd() { qmd_locked qmd-refresh-without-lock; }

qmd_models_manifest() {
    # Explicit init only: avoid QMD 2.8.3 pull deleting valid local models when
    # a transient HuggingFace HEAD failure leaves it without a remote ETag.
    python3 - "$1" "$runtime/qmd/models-manifest.json" "$runtime/cache/qmd/models" "$QMD_EMBED_MODEL" "$QMD_RERANK_MODEL" "$QMD_GENERATE_MODEL" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

action = sys.argv[1]
manifest = pathlib.Path(sys.argv[2])
cache = pathlib.Path(sys.argv[3])
try:
    if action == 'verify' and not manifest.is_file():
        sys.exit(1)
    actual = {'version': 1, 'models': {}}
    for uri in sys.argv[4:]:
        owner, _repository, filename = uri[3:].split('/')
        model = cache / f'hf_{owner}_{filename}'
        digest = hashlib.sha256()
        with model.open('rb') as stream:
            header = stream.read(4)
            if header != b'GGUF':
                sys.exit(1)
            digest.update(header)
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
            size = stream.tell()
        actual['models'][uri] = {
            'filename': model.name, 'size': size, 'sha256': digest.hexdigest(),
        }
    if action == 'verify':
        if json.loads(manifest.read_text()) != actual:
            sys.exit(1)
    elif action == 'record':
        temporary = manifest.with_name(manifest.name + '.tmp')
        temporary.write_text(json.dumps(actual, indent=2) + '\n')
        os.replace(temporary, manifest)
    else:
        sys.exit(2)
except (OSError, ValueError):
    sys.exit(1)
PY
}

init_qmd_without_lock() {
    require_cli qmd || return 1
    prepare_qmd_without_lock || return 1
    # Full first setup downloads all three models before declaring readiness.
    # Ordinary MCP startup never waits for this prefetch step.
    if qmd_models_manifest verify; then
        printf 'QMD model cache verified by SHA256; skipping model pull.\n' >&2
    else
        qmd_command pull || return 1
        # HF ETags can identify Xet objects rather than raw-file SHA256. Record
        # our own hashes only after the official complete pull has succeeded.
        qmd_models_manifest record || return 1
    fi
    refresh_qmd_without_lock
}

refresh_qmd_in_background() {
    require_cli python3 || return 1
    python3 "$lock_helper" --lock "$runtime/qmd/refresh.lock" --nonblocking --background --log "$runtime/qmd/refresh.log" -- /bin/bash "$script_path" qmd-refresh-without-lock
}

prepare_codegraph() {
    require_cli python3 || return 1
    # Keep this outside the store so a legacy root directory can still move.
    # Only init/sync hold this lock; the shared MCP daemon runs after release.
    python3 "$lock_helper" --lock "$runtime/codegraph-prepare.lock" -- /bin/bash "$script_path" "${1:-codegraph-prepare-without-lock}"
}

prepare_codegraph_without_lock() {
    local force="${1:-}" before after attempt adopt_result
    require_cli codegraph || return 1
    mkdir -p "$runtime" || return 1
    if [[ -L .codegraph ]]; then
        [[ "$(readlink .codegraph)" == "$codegraph_alias" ]] || {
            printf 'Existing .codegraph alias has another target; inspect it before migration.\n' >&2
            return 1
        }
    elif [[ -e .codegraph ]]; then
        [[ -d .codegraph && ! -e "$codegraph_data" ]] || {
            printf 'Existing CodeGraph stores conflict; inspect them before migration.\n' >&2
            return 1
        }
        mv .codegraph "$codegraph_data" || return 1
    fi
    mkdir -p "$codegraph_data" || return 1
    if [[ ! -L .codegraph ]]; then
        ln -s "$codegraph_alias" .codegraph || return 1
    fi
    if [[ -z "$force" ]] && retrieval_state graph-reusable; then
        printf 'CodeGraph shared watcher or unchanged offline sources ready; reusing prepared graph.\n' >&2
        return 0
    fi
    if [[ -z "$force" ]]; then
        if retrieval_state graph-adopt; then
            printf 'CodeGraph healthy shared watcher adopted; skipping initialization/sync.\n' >&2
            return 0
        else
            adopt_result=$?
            # A moving source snapshot needs another task-level refresh, not
            # an attempt to steal the healthy shared daemon's database lock.
            [[ "$adopt_result" != 75 ]] || return 1
        fi
    fi
    rm -f "$runtime/codegraph-prepared.json" || return 1
    # Official init checks the database schema, including interrupted/empty stores.
    # Prevent its automatic Git fallback hook installer on WSL / NO_WATCH hosts.
    # This override is scoped to init; the actual MCP keeps the host's watch policy.
    for attempt in 1 2 3; do
        before="$(retrieval_state graph-fingerprint)" || return 1
        env -u CODEGRAPH_NO_WATCH CODEGRAPH_FORCE_WATCH=1 codegraph init "$project_root" --yes || return 1
        codegraph sync || return 1
        after="$(retrieval_state graph-fingerprint)" || return 1
        if [[ "$before" == "$after" ]]; then
            if retrieval_state graph-record "$before"; then return 0; fi
            printf 'CodeGraph database/version is not ready; no prepared checkpoint recorded.\n' >&2
            return 1
        fi
        printf 'CodeGraph sources changed during sync; checking the newer snapshot (%s/3).\n' "$attempt" >&2
    done
    printf 'CodeGraph sources are still changing; no prepared checkpoint recorded.\n' >&2
    return 1
}

show_status() {
    if command -v qmd >/dev/null 2>&1 && [[ -f "$qmd_config/zero.yml" || -f "$qmd_config/zero.yaml" ]]; then
        qmd_command status
        qmd_command collection show zero-ai
    else
        printf 'QMD: adapter not initialized or CLI unavailable.\n'
    fi
    printf 'QMD refresh log: %s\n' "$runtime/qmd/refresh.log"
    if command -v codegraph >/dev/null 2>&1 && [[ -L .codegraph && "$(readlink .codegraph)" == "$codegraph_alias" && -f "$codegraph_data/codegraph.db" ]]; then
        codegraph status
    else
        printf 'CodeGraph: adapter not initialized or CLI unavailable.\n'
    fi
}

require_cli python3
preflight_owned_paths

case "$action" in
    setup|status|tools-prepare-without-lock) ;;
    *)
        # Even when a global CLI exists, this project uses its own locked tools.
        # All bootstrap output goes to stderr so stdio MCP stays JSON-RPC only.
        if ! tools_ready; then setup_tools >&2; fi
        ;;
esac

case "$action" in
    setup) setup_tools >&2 ;;
    tools-prepare-without-lock) setup_tools_without_lock ;;
    qmd-prepare) prepare_qmd_without_lock ;;
    qmd-init-without-lock) init_qmd_without_lock ;;
    qmd-refresh-without-lock) refresh_qmd_without_lock ;;
    qmd-force-without-lock) refresh_qmd_without_lock force ;;
    codegraph-prepare-without-lock) prepare_codegraph_without_lock ;;
    codegraph-force-without-lock) prepare_codegraph_without_lock force ;;
    status) show_status ;;
    init)
        result=0
        qmd_locked qmd-init-without-lock || result=1
        prepare_codegraph codegraph-force-without-lock || result=1
        exit "$result"
        ;;
    refresh)
        result=0
        refresh_qmd || result=1
        prepare_codegraph || result=1
        exit "$result"
        ;;
    refresh-force)
        result=0
        qmd_locked qmd-force-without-lock || result=1
        prepare_codegraph codegraph-force-without-lock || result=1
        exit "$result"
        ;;
    qmd)
        prepare_qmd >&2
        qmd_command "$@"
        ;;
    qmd-mcp)
        prepare_qmd >&2
        refresh_qmd_in_background >&2 || printf 'QMD background refresh could not start; the existing index remains available.\n' >&2
        exec qmd mcp --index zero
        ;;
    codegraph-mcp)
        prepare_codegraph >&2
        exec codegraph serve --mcp
        ;;
esac
