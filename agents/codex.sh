#!/usr/bin/env bash
#
# agents/codex.sh — OpenAI Codex CLI
#
# 路径红线：
#   ~/.codex/config.toml        可提交（本脚本渲染生成）
#   ~/.codex/auth.json          本脚本生成，**含密钥**，按 600 落盘
#   ~/.codex/ 下的 session 历史  ✗ 机器本地状态
#
# 关于认证：模板用 requires_openai_auth = true，这条路径读的是
# ~/.codex/auth.json 里的 OPENAI_API_KEY，而不是环境变量。
# 所以密钥写进 auth.json，config.toml 保持无密钥。

AGENT_NAME="${AGENT_NAME:-codex}"

CODEX_HOME="$HOME/.codex"
CODEX_REPO_DIR="$BOOTSTRAP_DIR/configs/codex"
CODEX_TMPL="$CODEX_REPO_DIR/config.toml.tmpl"
CODEX_AUTH_TMPL="$CODEX_REPO_DIR/auth.json.tmpl"

_CODEX_CUSTOM=0

agent_install() {
  if have codex; then
    ok "codex 已安装: $(codex --version 2>/dev/null | head -n1 || echo '版本未知')"
    return 0
  fi

  info "安装 Codex CLI（npm，需要 Node 22+）"

  if (( DRY_RUN )); then
    info "[dry-run] npm install -g @openai/codex"
    return 0
  fi

  ensure_node 22

  if ! have npm; then
    die "npm 不可用。请先安装 Node 22+ 后重试"
  fi

  npm install -g @openai/codex || die "npm 安装失败"
  hash -r 2>/dev/null || true
  ok "Codex CLI 安装完成"
}

agent_configure() {
  _collect_provider_vars

  # 默认值全部写在模板里（{{VAR|默认}}），此处只覆盖用户显式提供的部分，
  # 未提供时模板自带的默认值自然生效。
  install_rendered "$CODEX_TMPL" "$CODEX_HOME/config.toml"

  if (( _CODEX_CUSTOM )); then
    # requires_openai_auth 走的是 auth.json，不是环境变量
    install_rendered "$CODEX_AUTH_TMPL" "$CODEX_HOME/auth.json" --secret
  else
    info "未配置自定义 provider，不写 auth.json（保留 codex 自身登录态）"
  fi
}

_collect_provider_vars() {
  _CODEX_CUSTOM=0

  local use_custom=0

  if [[ -n "${CODEX_BASE_URL:-}" ]]; then
    use_custom=1
  elif (( NON_INTERACTIVE )) || ! have_tty; then
    use_custom=0
  elif confirm "为 Codex 配置自定义 model provider（中转 / 网关）?" y; then
    use_custom=1
  fi

  if (( ! use_custom )); then
    info "未配置自定义 provider，使用模板默认（走 codex 自身登录）"
    dim "注意：模板里的 model / provider 默认值是按中转场景写的，"
    dim "若非中转用途，请直接编辑 configs/codex/config.toml.tmpl 调整。"
    return 0
  fi

  ask CODEX_BASE_URL "Codex base_url" ""
  ask CODEX_MODEL "默认模型" "gpt-6-astra"
  ask CODEX_PROVIDER_NAME "provider 显示名" "custom"
  ask OPENAI_API_KEY "OpenAI API Key（不回显）" "" --secret

  bag_set BASE_URL       "$CODEX_BASE_URL"
  bag_set CODEX_MODEL    "$CODEX_MODEL"
  bag_set PROVIDER_NAME  "$CODEX_PROVIDER_NAME"
  bag_set OPENAI_API_KEY "$OPENAI_API_KEY"

  _CODEX_CUSTOM=1
}

agent_verify() {
  if have codex; then
    ok "codex: $(codex --version 2>/dev/null | head -n1 || echo '版本未知')"
  else
    warn "codex 不在 PATH 中，重开 shell 后再试"
  fi

  if (( DRY_RUN )); then
    info "dry-run：跳过落盘校验与探测"
    return 0
  fi

  if [[ -f "$CODEX_HOME/config.toml" ]]; then
    ok "配置 $CODEX_HOME/config.toml"
  else
    warn "未找到 $CODEX_HOME/config.toml"
  fi

  if [[ -f "$CODEX_HOME/auth.json" ]]; then
    # 同样要验：注入值里含引号会让 JSON 损坏，而损坏的 auth.json 表现为
    # 「配置都对但一直 401」，很难查。
    validate_json "$CODEX_HOME/auth.json"
  elif (( _CODEX_CUSTOM )); then
    warn "未找到 $CODEX_HOME/auth.json —— 自定义 provider 下密钥就存在这里"
  fi

  if (( ! VERIFY )); then
    dim "未做连通性探测（默认关闭；需要时加 --verify）"
    return 0
  fi

  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    warn "OPENAI_API_KEY 未设置，跳过探测"
    return 0
  fi

  _probe_codex
}

# 探测用的 UA 可覆盖（CODEX_PROBE_UA）。部分网关同样按 UA 判异常流量，
# 但 OpenAI 风格端点到底要什么 UA 还没测出来，所以默认沿用 curl 自带的，
# 需要时由用户显式指定。
_probe_codex() {
  local base="${CODEX_BASE_URL:-https://api.openai.com/v1}"
  base="${base%/}"
  local key="$OPENAI_API_KEY"
  local model="${CODEX_MODEL:-gpt-6-astra}"
  local auth="Authorization: Bearer $key"
  local ua="${CODEX_PROBE_UA:-}"

  info "探测端点 $base"

  # wire_api = "responses" 是硬约束：要求供应商支持 /responses。
  # 很多中转只有 /chat/completions，这时必须把 wire_api 改成 "chat"。
  probe_parse "$(probe_http "$base/responses" "$auth" \
    "$(printf '{"model":"%s","input":"ping","max_output_tokens":16}' "$model")" "$ua")"

  if probe_ok; then
    ok "/responses → HTTP $PROBE_CODE（响应体 $PROBE_KIND），wire_api = \"responses\" 正确"
    return 0
  fi

  case "$PROBE_CODE" in
    200)
      warn "/responses → HTTP 200，但响应体是 ${PROBE_KIND}，不是 API 响应"
      dim "网关/WAF 常对未知路径回 200 + 页面，别把它当成 /responses 可用" ;;
    401|403)
      warn "/responses → HTTP $PROBE_CODE 认证失败，检查 OPENAI_API_KEY"
      return 0 ;;
    000)
      warn "无法连接 $base/responses（DNS / TLS / 网络策略）"
      return 0 ;;
    5*)
      # 5xx = 端点存在、上游不可用。这不是"路径不存在" —— 让用户去改
      # base_url 只会把人带偏，还会白白丢掉一个本来正确的配置。
      warn "/responses → HTTP $PROBE_CODE：端点存在，但上游不可用（5xx）"
      dim "⇒ 多半是上游临时故障或限流，别动 base_url，稍后重试"
      return 0 ;;
    404|405)
      warn "/responses → HTTP $PROBE_CODE，该路径不存在" ;;
    *)
      warn "/responses → HTTP $PROBE_CODE（响应体 $PROBE_KIND）" ;;
  esac

  # 路径不通时，直接验证「补上 /v1 是否就好了」，给出确定结论而不是让用户猜
  if [[ "$base" != */v1 ]]; then
    dim "回退探测 $base/v1/responses …"
    probe_parse "$(probe_http "$base/v1/responses" "$auth" \
      "$(printf '{"model":"%s","input":"ping","max_output_tokens":16}' "$model")" "$ua")"
    if probe_ok; then
      warn "$base/v1/responses 可用（HTTP $PROBE_CODE）"
      dim "⇒ 把 config.toml 的 base_url 改成 \"$base/v1\""
      return 0
    fi
  fi

  dim "回退探测 /chat/completions …"
  probe_parse "$(probe_http "$base/chat/completions" "$auth" \
    "$(printf '{"model":"%s","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' "$model")" "$ua")"

  if probe_ok; then
    warn "但 /chat/completions 可用（HTTP $PROBE_CODE）"
    dim "⇒ 请把 $CODEX_HOME/config.toml 里的 wire_api 改成 \"chat\""
    return 0
  fi

  case "$PROBE_CODE" in
    404|405|000)
      warn "/chat/completions 也不可用（HTTP $PROBE_CODE）"
      dim "⇒ 核对 base_url 是否正确（当前: $base）" ;;
    5*)
      warn "/chat/completions → HTTP $PROBE_CODE：端点存在，上游不可用（5xx）"
      dim "⇒ 别改 base_url，稍后重试" ;;
    *)
      warn "/chat/completions → HTTP $PROBE_CODE（响应体 $PROBE_KIND）" ;;
  esac
}
