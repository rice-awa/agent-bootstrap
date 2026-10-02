#!/usr/bin/env bash
#
# agents/claude.sh — Claude Code
#
# 配置落地方式：**复制**（不用软链，见 lib/install.sh 的说明）。
#
# 密钥位置：Claude Code 的 settings.json 支持 "env" 块，会把里面的键值注入
# 到运行时环境。所以 ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN 直接写进
# ~/.claude/settings.json 的 env 里 —— 这是官方支持的位置，不需要再往
# shell profile 里塞 export。代价是该文件含密钥，因此按 600 落盘，
# 且提交进版本库的只有不含真实值的 .tmpl。
#
# 路径红线（这些路径混了 config 与机器本地状态，一律不碰）：
#   ~/.claude.json                 ✗ 含 OAuth、MCP 配置、项目 trust 状态
#   ~/.claude/.credentials.json    ✗ 凭证
#   ~/.claude/sessions/ history.jsonl cache/   ✗ 机器本地状态

AGENT_NAME="${AGENT_NAME:-claude}"

CLAUDE_HOME="$HOME/.claude"
CLAUDE_LOCAL_BIN="$HOME/.local/bin"
CLAUDE_REPO_DIR="$BOOTSTRAP_DIR/configs/claude"

_CLAUDE_CUSTOM=0

agent_install() {
  if have claude; then
    ok "claude 已安装: $(claude --version 2>/dev/null | head -n1 || echo '版本未知')"
    return 0
  fi

  info "安装 Claude Code（官方原生安装器，不依赖 Node）"

  if (( DRY_RUN )); then
    info "[dry-run] curl -fsSL https://claude.ai/install.sh | bash"
    return 0
  fi

  if have curl && curl -fsSL https://claude.ai/install.sh | bash; then
    ok "Claude Code 安装完成"
  else
    warn "原生安装器不可用，回退到 npm"
    _install_via_npm
  fi

  hash -r 2>/dev/null || true
}

_install_via_npm() {
  have npm || die "没有可用的 npm。请手动安装 Claude Code：
     https://code.claude.com/docs/en/setup"
  ensure_node 22
  info "npm install -g @anthropic-ai/claude-code"
  npm install -g @anthropic-ai/claude-code || die "npm 安装失败"
}

agent_configure() {
  mkdir -p "$CLAUDE_HOME"

  # 1) PATH：原生安装器落在 ~/.local/bin。必须无条件检查，不能只在
  #    「本次安装了」时补 —— 云环境重开 shell 后常见的情况是二进制已存在
  #    但 PATH 没生效，那条分支根本不会跑到。
  if [[ -x "$CLAUDE_LOCAL_BIN/claude" ]]; then
    ensure_path_entry "$CLAUDE_LOCAL_BIN"
  fi

  # 2) 收集端点与模型变量
  _configure_auth
  _configure_models

  # 3) 落盘
  if (( _CLAUDE_CUSTOM )); then
    install_rendered "$CLAUDE_REPO_DIR/settings.json.tmpl" \
                     "$CLAUDE_HOME/settings.json" --secret
  else
    info "未配置自定义端点，跳过 settings.json（claude 将使用自身登录态）"
    dim "需要写入请设 ANTHROPIC_BASE_URL 后重跑"
  fi

  install_copy "$CLAUDE_REPO_DIR/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md"
}

_configure_auth() {
  _CLAUDE_CUSTOM=0

  local use_custom=0
  if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    use_custom=1
  elif (( NON_INTERACTIVE )) || ! have_tty; then
    use_custom=0
  elif confirm "配置自定义 API 端点（中转/网关）?" n; then
    use_custom=1
  fi

  if (( ! use_custom )); then
    warn "未配置自定义端点。请任选其一完成认证："
    dim "a) 运行 claude 走交互登录（登录态约 7 天过期，不适合长期使用）"
    dim "b) 设 ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN 后重跑本脚本"
    return 0
  fi

  ask ANTHROPIC_BASE_URL "API 端点 (base URL)" ""
  ask ANTHROPIC_AUTH_TOKEN "网关 API Key" "" --secret

  # 注意：这里用 AUTH_TOKEN 而不是 API_KEY。网关认证走 Authorization: Bearer，
  # 对应 ANTHROPIC_AUTH_TOKEN；ANTHROPIC_API_KEY 走 x-api-key，是直连官方
  # API 用的。两者同时存在时 AUTH_TOKEN 优先级更高，会把 API_KEY 静默吃掉。
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    warn "环境中存在 ANTHROPIC_API_KEY：其优先级低于 ANTHROPIC_AUTH_TOKEN，"
    warn "会被静默忽略。如非本意请 unset 后再跑。"
  fi

  bag_set ANTHROPIC_BASE_URL  "$ANTHROPIC_BASE_URL"
  bag_set ANTHROPIC_AUTH_TOKEN "$ANTHROPIC_AUTH_TOKEN"
  _CLAUDE_CUSTOM=1
}

# 各模型层级默认值写在模板里。只有显式提供 ANTHROPIC_MODEL_ALIAS 时才
# 统一覆盖 —— 这样向导只需问两个问题，而不是八个。
_configure_models() {
  local __alias="${ANTHROPIC_MODEL_ALIAS:-}"
  [[ -n "$__alias" ]] || return 0

  local __tier
  for __tier in FABLE HAIKU OPUS SONNET; do
    bag_set "ANTHROPIC_DEFAULT_${__tier}_MODEL"      "$__alias"
    bag_set "ANTHROPIC_DEFAULT_${__tier}_MODEL_NAME" "$__alias"
  done
  ok "所有模型层级统一指向 $__alias（来自 ANTHROPIC_MODEL_ALIAS）"
}

# 交互登录的凭证落在哪，各平台说法不一（~/.claude/.credentials.json 还是
# ~/.claude.json）。与其猜字段名，不如两个位置都看一遍如实报告 ——
# 报告的目的是避免「配置里的 key」和「残留的登录态」互相打架时无从排查。
_report_login_state() {
  local __json="$HOME/.claude.json"
  local __found=0

  if [[ -f "$CLAUDE_HOME/.credentials.json" ]]; then
    warn "存在 $CLAUDE_HOME/.credentials.json（OAuth 凭证）"
    dim "若已改用 settings.json 的 env 认证，可删掉它以免混淆"
    __found=1
  fi

  # 只匹配键名，不读值。不同版本字段名不同，用宽松模式覆盖 oauthAccount /
  # oauthTokens / accessToken 这类命名，避免写死一个会漂移的键。
  if [[ -f "$__json" ]] && \
     grep -qE '"(oauth|credentials|accessToken|refreshToken)[A-Za-z]*"[[:space:]]*:' \
       "$__json" 2>/dev/null; then
    warn "$__json 里存有登录凭证"
    dim "与 settings.json 的 env 认证并存不冲突，但登录态约 7 天过期"
    __found=1
  fi

  if (( ! __found )); then
    dim "未发现交互登录态（走 settings.json 的 env 认证即可，无需登录）"
  fi
}

agent_verify() {
  if have claude; then
    ok "claude: $(claude --version 2>/dev/null | head -n1 || echo '版本未知')"
  else
    warn "claude 不在 PATH 中（可能装到了 $CLAUDE_LOCAL_BIN，重开 shell 后再试）"
  fi

  if (( DRY_RUN )); then
    info "dry-run：跳过落盘校验与探测"
    return 0
  fi

  if [[ -f "$CLAUDE_HOME/settings.json" ]]; then
    # 模板渲染是纯文本替换，注入值里若含引号/反斜杠会产出损坏的 JSON，
    # 而损坏的 settings.json 会让 claude 静默失效 —— 值得当场验一次。
    validate_json "$CLAUDE_HOME/settings.json"
  else
    info "未部署 $CLAUDE_HOME/settings.json"
  fi

  _report_login_state

  if (( ! VERIFY )); then
    dim "未做连通性探测（默认关闭；需要时加 --verify）"
    return 0
  fi

  if [[ -z "${ANTHROPIC_BASE_URL:-}" ]]; then
    info "未配置自定义端点，跳过探测"
    return 0
  fi

  _probe_anthropic
}

# 探测用的 User-Agent。不少中转按 UA 做渠道健康策略：UA 不以 claude-cli/
# 开头会被判成异常流量并**停用渠道**，连累所有客户端（包括正在用的会话）。
# 真实客户端的 UA 形如 "claude-cli/2.1.287 (external, cli)"；版本号无所谓，
# 但能取到本地版本就用本地的，免得硬编码后随版本漂移。
_claude_probe_ua() {
  local __v
  __v="$(claude --version 2>/dev/null | head -n1 | awk '{print $1}')"
  [[ "$__v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || __v="2.1.161"
  printf 'claude-cli/%s (external, cli)' "$__v"
}

_probe_anthropic() {
  local base="${ANTHROPIC_BASE_URL%/}"
  local auth

  if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    auth="Authorization: Bearer $ANTHROPIC_AUTH_TOKEN"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    auth="x-api-key: $ANTHROPIC_API_KEY"
  else
    warn "没有可用的密钥，跳过探测"
    return 0
  fi

  local model="${ANTHROPIC_MODEL:-claude-haiku-4-5-20251001}"
  local ua body url
  ua="$(_claude_probe_ua)"
  body="$(printf '{"model":"%s","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}' "$model")"

  info "探测端点 $base（会发一次最小请求，UA: $ua）"

  # base_url 带不带 /v1 因供应商而异，两种候选都试再下结论。
  # 注意：若 base 已以 /v1 结尾就不能再拼 /v1 —— 会变成 /v1/v1。
  local -a candidates=()
  if [[ "$base" == */v1 ]]; then
    candidates=("$base/messages")
  else
    candidates=("$base/v1/messages" "$base/messages")
  fi

  for url in "${candidates[@]}"; do
    probe_parse "$(probe_http "$url" "$auth" "$body" "$ua")"

    if probe_ok; then
      ok "$url → HTTP $PROBE_CODE（响应体 $PROBE_KIND），配置可用"
      return 0
    fi

    case "$PROBE_CODE" in
      200)
        # 网关 / WAF 对未知路径常回 200 + HTML 首页。把它当成功是最坏的结果：
        # 用户以为配好了，真实客户端拿到的却是页面，直接报 malformed response。
        warn "$url → HTTP 200，但响应体是 ${PROBE_KIND}，不是 API 响应"
        dim "网关/WAF 常对未知路径回 200 + 页面；真实客户端会报 malformed response" ;;
      400|422)
        dim "$url → HTTP $PROBE_CODE 但响应体是 ${PROBE_KIND}，疑似网关拦截" ;;
      401|403)
        warn "$url → HTTP $PROBE_CODE 认证失败，请检查 API Key"
        return 0 ;;
      404|405)
        dim "$url → HTTP $PROBE_CODE" ;;
      000)
        warn "$url → 无法连接（DNS / TLS / 网络策略）" ;;
      *)
        dim "$url → HTTP $PROBE_CODE（响应体 $PROBE_KIND）" ;;
    esac
  done

  warn "两个候选路径都不可用。请核对该供应商要求 ANTHROPIC_BASE_URL 是否需要以 /v1 结尾。"
}
