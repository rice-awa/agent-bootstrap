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
  # 管道执行：stdin 是脚本自身，拿不到同目录的 lib/ 和 agents/，
  # 所以得先弄一份完整副本到临时目录，再交给自己跑。
  #
  # 两条路径，优先不走 git：不少网络策略放行 GitHub 的 CDN
  # （raw / codeload）却拦 github.com 本体，而 git clone 打的正是
  # github.com —— 一旦被拦，整条一行命令就卡死。tar 包走的是 CDN，
  # 顺带也不需要机器上装 git。
  : "${AGENT_BOOTSTRAP_REPO:=https://github.com/rice-awa/agent-bootstrap.git}"
  : "${AGENT_BOOTSTRAP_REF:=main}"

  _fetched=0

  if [[ "$AGENT_BOOTSTRAP_REPO" =~ ^https?://github\.com/([^/]+)/([^/]+)$ ]] \
     && command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    _owner="${BASH_REMATCH[1]}"
    _name="${BASH_REMATCH[2]%.git}"
    _tmp="$(mktemp -d)"
    if curl -fsSL --max-time 60 \
         "https://codeload.github.com/${_owner}/${_name}/tar.gz/refs/heads/${AGENT_BOOTSTRAP_REF}" \
         | tar -xz -C "$_tmp" --strip-components=1 2>/dev/null \
       && [[ -f "$_tmp/bootstrap.sh" ]]; then
      _fetched=1
    fi
  fi

  if (( ! _fetched )); then
    command -v git >/dev/null 2>&1 || _early_die "取不到脚本本体：tar 包下载失败，且机器上没有 git。

请手动下载仓库后本地运行：
  ./bootstrap.sh --all"
    _tmp="$(mktemp -d)"
    git clone --depth 1 --branch "$AGENT_BOOTSTRAP_REF" "$AGENT_BOOTSTRAP_REPO" "$_tmp" >&2 \
      || _early_die "克隆失败: $AGENT_BOOTSTRAP_REPO"
    [[ -f "$_tmp/bootstrap.sh" ]] || _early_die "取到的内容里没有 bootstrap.sh，地址对吗？"
  fi

  exec bash "$_tmp/bootstrap.sh" "$@"
fi

# ── 选项（必须在加载 lib 之前初始化：lib 里用 `set -u` 引用它们）──
AGENTS_ARG=""
NON_INTERACTIVE=0
FORCE=0
DRY_RUN=0
INSTALL_ONLY=0  # 仅安装 CLI，跳过配置与凭据收集
VERIFY=0        # 联网探测默认关闭：见 usage 里 --verify 的说明

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
  -i, --install-only     只安装 CLI，跳过配置与凭据收集
  -y, --non-interactive  非交互：只用环境变量，缺失即失败，绝不等待输入
  -f, --force            覆盖已存在的配置文件（会先备份）
  -n, --dry-run          只打印将要执行的动作，不落盘
      --verify           安装后向端点发一次探测请求，验证连通与认证
                         （默认不发任何请求，见下）
      --skip-verify      兼容旧用法，等同默认行为（不探测）
  -l, --list             列出已知 agent
  -h, --help             显示本帮助
  -V, --version          显示版本

凭据来源（优先级从高到低）:
  环境变量 / 平台 secret → 交互终端向导（密钥不回显）→ 默认值 → 报错退出

默认不探测: 探测收益低、风险高（请求头与真实客户端不一致时，中转可能停用
  渠道），所以默认零网络请求，需要时加 --verify。

落盘位置:
  ~/.claude/settings.json      由 configs/claude/settings.json.tmpl 渲染（含密钥，600）
  ~/.claude/CLAUDE.md          从 configs/claude/CLAUDE.md 复制
  ~/.codex/config.toml         由 configs/codex/config.toml.tmpl 渲染（不含密钥）
  ~/.codex/auth.json           由 configs/codex/auth.json.tmpl 渲染（含密钥，600）
  ~/.config/agent-env.d/00-path.sh  往 PATH 里加 ~/.local/bin
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
    --verify)           VERIFY=1; shift ;;
    --skip-verify)      VERIFY=0; shift ;;
    -i|--install-only)  INSTALL_ONLY=1; shift ;;
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
  ask AGENTS_ARG "处理哪些 agent（claude, codex，或 all）" "all"
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

  local -a __steps=(agent_install agent_configure agent_verify)
  (( INSTALL_ONLY )) && __steps=(agent_install)

  if (
    AGENT_NAME="$__name"
    # shellcheck disable=SC1090
    source "$__mod"
    for __fn in "${__steps[@]}"; do
      "$__fn" || exit 1
    done
  ); then
    if (( INSTALL_ONLY )); then
      ok "${__name} 安装完成"
    else
      ok "${__name} 处理完成"
    fi
    return 0
  fi

  err "${__name} 处理失败（见上方日志）"
  return 1
}

info "agent-bootstrap $BOOTSTRAP_VERSION —— 目标: ${AGENT_LIST[*]}"
(( DRY_RUN )) && warn "dry-run 模式：不会真正落盘"
(( INSTALL_ONLY )) && warn "仅安装模式：跳过配置与凭据收集"

if (( ! INSTALL_ONLY )); then
  ensure_env_sourced
fi

FAILED=()
for _agent in "${AGENT_LIST[@]}"; do
  process_agent "$_agent" || FAILED+=("$_agent")
done

# ── 汇总 ───────────────────────────────────────────────────────
printf '\n' >&2
if (( ${#FAILED[@]} == 0 )); then
  if (( INSTALL_ONLY )); then
    ok "全部安装完成。"
  else
    ok "全部完成。"
    dim "新开一个 shell，或执行： source ~/.bashrc"
  fi
else
  err "以下 agent 失败: ${FAILED[*]}"
  exit 1
fi
