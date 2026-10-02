#!/usr/bin/env bash
#
# lib/install.sh — 通用安装 / 落盘 / 探测原语

[[ -n "${_AB_INSTALL_LOADED:-}" ]] && return 0
_AB_INSTALL_LOADED=1

# 允许本文件被单独 source（测试 / 新 agent 调试）而不必先跑 bootstrap.sh
: "${DRY_RUN:=0}"
: "${FORCE:=0}"
: "${VERIFY:=0}"   # 联网探测默认关闭，要 --verify 才开

have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || die "缺少依赖命令: $1"; }

# ── 备份 ────────────────────────────────────────────────────────
backup_file() {
  local __f="$1"
  local __bak="${__f}.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$__f" "$__bak" && ok "已备份 → $__bak"
}

# ── 部署单个配置文件 ────────────────────────────────────────────
# 全部用复制，不用软链：软链在部分文件系统（Windows/Cygwin、某些
# overlay/NFS 挂载）会静默退化成复制，行为不一致；而复制到处都一样。
#
# 判断「文件还是不是我们上次部署的样子」，靠的是上次部署内容的副本
# （<dst>.last-deployed），不用文件头标记 —— 标记会随每版输出一起被复制，
# 区分不出用户改没改过，而且 JSON 根本放不了注释。
#
# secret=1 时按密钥对待：chmod 600，且副本同样处理（副本里也有密钥）。
_install_content() {
  local __dst="$1" __tmp="$2" __secret="$3"
  local __stamp="${__dst}.last-deployed"

  if [[ -f "$__dst" ]] && cmp -s "$__tmp" "$__dst"; then
    ok "无变化 $__dst"
    cp -f "$__tmp" "$__stamp"
    (( __secret )) && chmod_secret "$__stamp"
    return 0
  fi

  if [[ -e "$__dst" ]]; then
    local __ours=0
    if [[ -f "$__stamp" ]] && cmp -s "$__dst" "$__stamp"; then
      __ours=1   # 自上次部署后没人动过
    elif [[ ! -f "$__stamp" ]] && \
         head -n 3 "$__dst" 2>/dev/null | grep -q 'generated-by: agent-bootstrap'; then
      __ours=1   # 本脚本早期版本生成的（一次性兼容路径）
    fi

    if (( ! __ours )) && (( ! FORCE )); then
      warn "$__dst 已存在且不是本工具部署的，跳过以免覆盖你的内容"
      dim "确认要覆盖，请加 --force（会先备份）"
      return 0
    fi
    backup_file "$__dst"
  fi

  cp -f "$__tmp" "$__dst"
  cp -f "$__tmp" "$__stamp"

  if (( __secret )); then
    chmod_secret "$__dst"
    chmod_secret "$__stamp"
  else
    ok "已写入 $__dst"
  fi
}

# install_rendered <模板> <目标> [--secret]
install_rendered() {
  local __tmpl="$1" __dst="$2" __secret=0
  [[ "${3:-}" == "--secret" ]] && __secret=1

  [[ -f "$__tmpl" ]] || die "模板不存在: $__tmpl"

  if (( DRY_RUN )); then
    info "[dry-run] 渲染 $__tmpl → $__dst"
    return 0
  fi

  mkdir -p "$(dirname "$__dst")"
  local __tmp
  __tmp="$(mktemp)"
  render_to "$__tmpl" "$__tmp"
  _install_content "$__dst" "$__tmp" "$__secret"
  rm -f "$__tmp"
}

# install_copy <源文件> <目标> [--secret]
install_copy() {
  local __src="$1" __dst="$2" __secret=0
  [[ "${3:-}" == "--secret" ]] && __secret=1

  if [[ ! -f "$__src" ]]; then
    warn "源文件不存在，跳过: $__src"
    return 0
  fi

  if (( DRY_RUN )); then
    info "[dry-run] 复制 $__src → $__dst"
    return 0
  fi

  mkdir -p "$(dirname "$__dst")"
  local __tmp
  __tmp="$(mktemp)"
  cp -f "$__src" "$__tmp"
  _install_content "$__dst" "$__tmp" "$__secret"
  rm -f "$__tmp"
}

# ── JSON 校验（尽力而为）────────────────────────────────────────
# 模板渲染是纯文本替换：若注入值里含 " 或 \，产出的 JSON 会损坏，
# 而损坏的 settings.json 会让工具静默失效。有解释器就验一下。
#
# 返回值：0=合法  1=JSON 非法  2=解释器不可用
_validate_with() {
  local __exe="$1" __f="$2"

  # 先确认解释器本身能跑。Windows 应用商店的 python3 别名、坏掉的 venv
  # 都是「命令存在但执行失败」—— 必须与「JSON 非法」区分开，否则会发出
  # 吓人的假警报，把一个完全正常的配置报成坏的。
  "$__exe" -c 'pass' >/dev/null 2>&1 || return 2
  "$__exe" -c 'import json,sys; json.load(open(sys.argv[1]))' "$__f" >/dev/null 2>&1 \
    || return 1
  return 0
}

validate_json() {
  local __f="$1" __exe __rc=2

  for __exe in python3 python; do
    have "$__exe" || continue
    _validate_with "$__exe" "$__f" && __rc=0 && break
    __rc=$?
    (( __rc == 1 )) && break      # 解释器可用且判定非法，无需再试别的
  done

  case "$__rc" in
    0) ok "JSON 合法 $__f" ;;
    1)
      err "$__f 不是合法 JSON —— 通常是注入值里含有引号或反斜杠"
      dim "用 python3 -m json.tool '$__f' 查看具体位置" ;;
    *)
      dim "无可用 python，跳过 JSON 校验 $__f" ;;
  esac
}

# ── Node ───────────────────────────────────────────────────────
_node_major() {
  have node || return 1
  node -p 'process.versions.node.split(".")[0]' 2>/dev/null
}

# ensure_node <最低主版本>
ensure_node() {
  local __want="${1:-22}" __cur

  __cur="$(_node_major 2>/dev/null || echo 0)"

  if [[ "$__cur" =~ ^[0-9]+$ ]] && (( __cur >= __want )); then
    ok "node v$__cur 满足要求（>= $__want）"
    return 0
  fi

  warn "需要 node >= $__want，当前: $(have node && node -v || echo '未安装')"

  if (( DRY_RUN )); then
    info "[dry-run] 需要安装 node >= $__want"
    return 0
  fi

  local __nvm_sh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  if [[ -s "$__nvm_sh" ]]; then
    info "通过 nvm 安装 node $__want"
    # shellcheck disable=SC1090
    . "$__nvm_sh"
    nvm install "$__want" && nvm use "$__want" && return 0
  fi

  die "无法自动安装 node $__want。请先手动安装后重试，例如：
     nvm:  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash && nvm install $__want
     apt:  见 https://github.com/nodesource/distributions"
}

# ── 端点探测 ───────────────────────────────────────────────────
# 默认不联网探测（见 bootstrap.sh 的 --verify）：探测只换来"端点通不通"
# 这一点信息，代价却不对称 —— 请求头与真实客户端不一致时，中转可能把
# 它判成异常流量并**停用渠道**，连带影响所有客户端。所以宁可默认不发。
#
# probe_http <url> <auth头> <body> [user-agent]
# 输出 "<HTTP 状态码> <响应体类型>"，用空格分隔：
#   状态码  三位数字；网络层失败为 000
#   类型    json | html | other | empty | none
#
# 为什么必须看响应体，而不是只看状态码：网关 / WAF 对未知路径常返回
# 200 + HTML 首页。只看状态码会把它当成"端点可用"，而真实客户端拿到
# HTML 后直接报 malformed response。
#
# 判断类型为什么不能看 Content-Type：实测有网关用 text/plain 返回合法
# JSON 体。所以按内容判断 —— 首个非空白字符是 { 或 [ 即算 JSON，是 <
# 即算 HTML（任何标记语言都归此类）。
probe_http() {
  local __url="$1" __auth="$2" __body="$3" __ua="${4:-}"
  local __out __code __text __trim __kind=empty

  if ! have curl; then
    printf '000 none'
    return 0
  fi

  # 响应体走 stdout，状态码由 -w 追加在最后一行。curl 连接失败时同样会
  # 输出 000 并以非 0 退出 —— 不要用 `|| printf 000` 兜底，那会拼成
  # "000000"，落到 case 的 *) 分支给出误导性提示。
  local -a __args=(
    -sS -o - -w '\n%{http_code}' --max-time 20
    -X POST "$__url"
    -H "$__auth"
    -H 'Content-Type: application/json'
    -d "$__body"
  )
  if [[ -n "$__ua" ]]; then
    __args+=(-H "User-Agent: $__ua")
  fi

  __out="$(curl "${__args[@]}" 2>/dev/null)" || true

  # 最后一行是状态码，其余是响应体
  __code="${__out##*$'\n'}"
  __text="${__out%$'\n'*}"
  [[ "$__code" =~ ^[0-9]{3}$ ]] || __code=000

  if [[ "$__code" != "000" ]]; then
    # 只取开头一小段做类型判断，避免大响应体白白占内存
    __trim="${__text:0:200}"
    __trim="${__trim#"${__trim%%[![:space:]]*}"}"   # 去掉前导空白
    if [[ -n "$__trim" ]]; then
      case "$__trim" in
        \{*|\[*) __kind=json ;;
        '<'*)    __kind=html ;;
        *)       __kind=other ;;
      esac
    fi
  else
    __kind=none
  fi

  printf '%s %s' "$__code" "$__kind"
}

# 拆开 probe_http 的输出：probe_parse "<code> <kind>"
# 结果落在 PROBE_CODE / PROBE_KIND 两个全局变量上（探测都在当前 shell 跑，
# 不像 command substitution 那样丢子 shell，所以变量能带出来）。
probe_parse() {
  PROBE_CODE="${1%% *}"
  PROBE_KIND="${1##* }"
}

# probe_ok — 当前的 PROBE_CODE / PROBE_KIND 是否说明「端点确实在提供 API」。
#   200    必须响应体是 JSON。HTML 的 200 是网关拦截，不是成功。
#   400/422 只要不是网关页面，就说明请求已经进到 API 内部（认证已过，
#           只是请求体或模型名不合），这也算端点可用。
probe_ok() {
  case "$PROBE_CODE" in
    200)     [[ "$PROBE_KIND" == json ]] ;;
    400|422) [[ "$PROBE_KIND" != html && "$PROBE_KIND" != empty ]] ;;
    *)       return 1 ;;
  esac
}
