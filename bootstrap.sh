#!/usr/bin/env bash
#
# agent-bootstrap — 云端 Linux 开发环境一键拉起 coding agent 配置
#
# 用法见 ./bootstrap.sh --help
#
set -euo pipefail

BOOTSTRAP_VERSION="0.1.0"
KNOWN_AGENTS=(claude codex)

# ── 早期诊断（此时 lib/ 还没加载，只能自己报错）─────────────────
_early_die() { printf '错误: %s\n' "$*" >&2; exit 1; }

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  _early_die "需要 bash 4.0+（当前 ${BASH_VERSION:-unknown}）"
fi

# ── 自身定位：同时支持本地 checkout 和 curl | bash ─────────────
_self="${BASH_SOURCE[0]:-}"
BOOTSTRAP_DIR=""
if [[ -n "$_self" && -f "$_self" ]]; then
  BOOTSTRAP_DIR="$(cd "$(dirname "$_self")" && pwd)"
fi

if [[ -z "$BOOTSTRAP_DIR" || ! -f "$BOOTSTRAP_DIR/lib/ui.sh" ]]; then
  # 管道执行：拿不到本地文件，克隆一份再交给自己
  _repo="${AGENT_BOOTSTRAP_REPO:-}"
  if [[ -z "$_repo" ]]; then
    _early_die "检测到管道执行，但没有本地文件，且未设置 AGENT_BOOTSTRAP_REPO。

请任选其一：
  1) 克隆仓库后本地运行：  ./bootstrap.sh --all
  2) 指定仓库地址：       AGENT_BOOTSTRAP_REPO=<git-url> curl -fsSL <raw-url> | bash"
  fi
  command -v git >/dev/null 2>&1 || _early_die "缺少 git"
  _tmp="$(mktemp -d)"
  git clone --depth 1 "$_repo" "$_tmp/agent-bootstrap" >/dev/null 2>&1 \
    || _early_die "克隆失败: $_repo"
  exec bash "$_tmp/agent-bootstrap/bootstrap.sh" "$@"
fi

# ── 选项（必须在加载 lib 之前初始化：lib 里用 `set -u` 引用它们）──
AGENTS_ARG=""
NON_INTERACTIVE=0
FORCE=0
DRY_RUN=0
SKIP_VERIFY=0

# ── 加载 lib ───────────────────────────────────────────────────
# shellcheck source=lib/ui.sh
source "$BOOTSTRAP_DIR/lib/ui.sh"
# shellcheck source=lib/render.sh
source "$BOOTSTRAP_DIR/lib/render.sh"
# shellcheck source=lib/credentials.sh
source "$BOOTSTRAP_DIR/lib/credentials.sh"
# shellcheck source=lib/install.sh
source "$BOOTSTRAP_DIR/lib/install.sh"

# ── 帮助 ───────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
agent-bootstrap — 云端一键拉起 coding agent 配置

用法:
  ./bootstrap.sh [选项]

选项:
  -a, --agent LIST       指定 agent，逗号分隔（claude,codex）
      --all              处理所有已知 agent
  -y, --non-interactive  非交互：只用环境变量，缺失即失败，绝不等待输入
  -f, --force            覆盖已存在的配置文件（会先备份）
  -n, --dry-run          只打印将要执行的动作，不落盘
      --skip-verify      跳过安装后的连通性探测
  -l, --list             列出已知 agent
  -h, --help             显示本帮助
  -V, --version          显示版本

凭据解析顺序（三级）:
  1. 环境变量 / 平台 secret 已存在  → 直接采用，不打扰
  2. 有可交互终端                  → 向导询问（密钥不回显）
  3. 否则                          → 有默认值用默认值，没有则报错退出

落盘位置:
  ~/.config/agent-env.d/*.sh   密钥（chmod 600，由 ~/.bashrc 加载）
  ~/.claude/settings.json      软链到本仓库 configs/claude/
  ~/.codex/config.toml         由 configs/codex/config.toml.tmpl 渲染
EOF
}

while (( $# )); do
  case "$1" in
    -a|--agent)
      [[ -n "${2:-}" ]] || _early_die "--agent 需要一个参数"
      AGENTS_ARG="$2"; shift 2 ;;
    --agent=*)          AGENTS_ARG="${1#*=}"; shift ;;
    --all)              AGENTS_ARG="all"; shift ;;
    -y|--non-interactive) NON_INTERACTIVE=1; shift ;;
    -f|--force)         FORCE=1; shift ;;
    -n|--dry-run)       DRY_RUN=1; shift ;;
    --skip-verify)      SKIP_VERIFY=1; shift ;;
    -l|--list)          printf '%s\n' "${KNOWN_AGENTS[@]}"; exit 0 ;;
    -h|--help)          usage; exit 0 ;;
    -V|--version)       printf 'agent-bootstrap %s\n' "$BOOTSTRAP_VERSION"; exit 0 ;;
    *)                  _early_die "未知参数: $1（-h 查看用法）" ;;
  esac
done

# ── 解析 agent 列表 ────────────────────────────────────────────
AGENT_LIST=()

_resolve_agents() {
  local __spec="$1" __a __k __known
  AGENT_LIST=()

  if [[ "$__spec" == "all" ]]; then
    AGENT_LIST=("${KNOWN_AGENTS[@]}")
    return 0
  fi

  local IFS=','
  for __a in $__spec; do
    __a="${__a// /}"
    [[ -n "$__a" ]] || continue
    __known=0
    for __k in "${KNOWN_AGENTS[@]}"; do
      [[ "$__a" == "$__k" ]] && { __known=1; break; }
    done
    (( __known )) || die "未知 agent: $__a（可选: ${KNOWN_AGENTS[*]}）"
    AGENT_LIST+=("$__a")
  done

  (( ${#AGENT_LIST[@]} )) || die "--agent 未指定有效值"
}

if [[ -z "$AGENTS_ARG" ]]; then
  if (( NON_INTERACTIVE )) || ! have_tty; then
    die "未指定 agent。非交互模式下请用 --agent 或 --all"
  fi
  ask AGENTS_ARG "要处理哪些 agent（逗号分隔，或 all）" "all"
fi

_resolve_agents "$AGENTS_ARG"

# ── 执行 ───────────────────────────────────────────────────────
# 每个 agent 在独立子 shell 中运行：模块之间的函数名不会互相污染，
# BAG（模板变量）也天然按 agent 隔离。
process_agent() {
  local __name="$1"
  local __mod="$BOOTSTRAP_DIR/agents/${__name}.sh"

  printf '\n' >&2
  info "═══ ${__name} ═══"

  if [[ ! -f "$__mod" ]]; then
    err "找不到模块: $__mod"
    return 1
  fi

  if (
    AGENT_NAME="$__name"
    # shellcheck disable=SC1090
    source "$__mod"
    agent_install && agent_configure && agent_verify
  ); then
    ok "${__name} 处理完成"
    return 0
  fi

  err "${__name} 处理失败（见上方日志）"
  return 1
}

info "agent-bootstrap $BOOTSTRAP_VERSION —— 目标: ${AGENT_LIST[*]}"
(( DRY_RUN )) && warn "dry-run 模式：不会真正落盘"

ensure_env_sourced

FAILED=()
for _agent in "${AGENT_LIST[@]}"; do
  process_agent "$_agent" || FAILED+=("$_agent")
done

# ── 汇总 ───────────────────────────────────────────────────────
printf '\n' >&2
if (( ${#FAILED[@]} == 0 )); then
  ok "全部完成。"
  dim "新开一个 shell，或执行： source ~/.bashrc"
else
  err "以下 agent 失败: ${FAILED[*]}"
  exit 1
fi
