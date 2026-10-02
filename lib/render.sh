#!/usr/bin/env bash
#
# lib/render.sh — 极简模板渲染
#
# 语法：
#   {{KEY}}            → BAG[KEY]，未设置则渲染为空
#   {{KEY|默认值}}     → BAG[KEY]，未设置则用默认值
#
# 默认值必须写在模板里而不是代码里 —— 这样「什么算默认、什么算变量」
# 一眼就能从 .tmpl 文件本身看出来，不需要去翻 shell 代码。

[[ -n "${_AB_RENDER_LOADED:-}" ]] && return 0
_AB_RENDER_LOADED=1

declare -A BAG=()

bag_set() { BAG["$1"]="$2"; }
bag_dump() {
  local __k
  for __k in "${!BAG[@]}"; do dim "$__k=${BAG[$__k]}"; done
}

# render_to <模板> <输出路径>
render_to() {
  local __src="$1" __dst="$2"
  local __line __whole __key __def __val __guard

  [[ -f "$__src" ]] || die "模板文件不存在: $__src"
  : > "$__dst" || die "无法写入: $__dst"

  while IFS= read -r __line || [[ -n "$__line" ]]; do
    __guard=0
    while [[ "$__line" =~ \{\{([A-Za-z_][A-Za-z0-9_]*)(\|([^}]*))?\}\} ]]; do
      # 防止值里含占位符导致死循环
      (( ++__guard > 64 )) && die "模板渲染疑似死循环: $__src"

      __whole="${BASH_REMATCH[0]}"
      __key="${BASH_REMATCH[1]}"
      __def="${BASH_REMATCH[3]:-}"
      __val="${BAG[$__key]:-$__def}"

      # 两侧都加引号 → 整体按字面量替换，值里的特殊字符不会被当作模式
      __line="${__line/"$__whole"/"$__val"}"
    done
    printf '%s\n' "$__line" >> "$__dst"
  done < "$__src"
}
