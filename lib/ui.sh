#!/usr/bin/env bash
#
# lib/ui.sh — 日志与交互原语
#
# 关键约束：本脚本常以 `curl … | bash` 方式运行，此时 stdin 是**脚本自身**。
# 任何交互都必须从 /dev/tty 读取，否则 read 会吃掉脚本内容，行为诡异。
# 所有提示输出一律走 stderr 或 /dev/tty，保持 stdout 干净（可被管道消费）。

[[ -n "${_AB_UI_LOADED:-}" ]] && return 0
_AB_UI_LOADED=1

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'
  C_RED=$'\033[31m';  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'
else
  C_RESET=; C_DIM=; C_BLD=; C_RED=; C_GRN=; C_YEL=; C_BLU=
fi

info() { printf '%s\n' "${C_BLU}==>${C_RESET} $*" >&2; }
ok()   { printf '%s\n' "${C_GRN}  ✓${C_RESET} $*" >&2; }
warn() { printf '%s\n' "${C_YEL}  !${C_RESET} $*" >&2; }
err()  { printf '%s\n' "${C_RED}  ✗${C_RESET} $*" >&2; }
dim()  { printf '%s\n' "${C_DIM}    $*${C_RESET}" >&2; }
die()  { err "$*"; exit 1; }

# 是否存在可用于交互的终端设备
have_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }

# ask VAR "提示语" [默认值] [--secret]
#
# 三级解析 —— 这是整个脚本的骨架，决定了它既能被 CI 无人值守调用，
# 也能被人手动跑起来开箱填写：
#   1. 目标变量已由环境变量 / 平台 secret 提供 → 直接采用，不作打扰
#   2. 有可交互终端且非 --non-interactive → 询问（密钥不回显）
#   3. 否则：有默认值就用默认值，没有就报错退出（绝不静默用空值）
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __secret="${4:-}"
  local __cur="${!__var:-}"

  if [[ -n "$__cur" ]]; then
    ok "$__var 已由环境提供，跳过询问"
    return 0
  fi

  if (( NON_INTERACTIVE )) || ! have_tty; then
    if [[ -n "$__default" ]]; then
      printf -v "$__var" '%s' "$__default"
      warn "$__var 未提供，使用默认值：$__default"
      return 0
    fi
    die "$__var 未提供，且当前无法交互（--non-interactive 或没有可用的 /dev/tty）"
  fi

  local __in="" __p="$__prompt"
  [[ -n "$__default" ]] && __p="$__p [$__default]"

  while :; do
    if [[ "$__secret" == "--secret" ]]; then
      IFS= read -rs -p "$__p: " __in < /dev/tty || die "读取输入被中断"
      printf '\n' > /dev/tty
    else
      IFS= read -r -p "$__p: " __in < /dev/tty || die "读取输入被中断"
    fi
    [[ -z "$__in" && -n "$__default" ]] && __in="$__default"
    [[ -n "$__in" ]] && break
    warn "输入不能为空，请重试"
  done

  printf -v "$__var" '%s' "$__in"
}

# confirm "提示语" [y|n] —— 返回 0 表示是
confirm() {
  local __p="$1" __def="${2:-y}" __in=""

  if (( NON_INTERACTIVE )) || ! have_tty; then
    [[ "$__def" == "y" ]]
    return
  fi

  local __hint="[Y/n]"
  [[ "$__def" == "n" ]] && __hint="[y/N]"

  IFS= read -r -p "$__p $__hint " __in < /dev/tty || return 1
  __in="${__in:-$__def}"
  [[ "${__in,,}" == "y" || "${__in,,}" == "yes" ]]
}
