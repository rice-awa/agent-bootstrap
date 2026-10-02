#!/usr/bin/env bash
#
# lib/credentials.sh — 凭据落盘与 shell 集成
#
# 设计要点：配置文件里**不放密钥**。
#   · configs/ 里的模板只含 base_url 这类非敏感值，可以直接提交进版本库
#   · 真正的密钥写进 ~/.config/agent-env.d/<agent>.sh（chmod 600），由 .bashrc 加载
# 每个 agent 一个文件，互不覆盖；重跑某个 agent 不会动到别的 agent 的密钥。

[[ -n "${_AB_CRED_LOADED:-}" ]] && return 0
_AB_CRED_LOADED=1

# 允许本文件被单独 source（测试 / 新 agent 调试）而不必先跑 bootstrap.sh
: "${DRY_RUN:=0}"
: "${FORCE:=0}"

AGENT_ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-env.d"
ENV_MARKER_BEGIN="# >>> agent-bootstrap env >>>"
ENV_MARKER_END="# <<< agent-bootstrap env <<<"

# ── chmod 600 并回读校验 ────────────────────────────────────────
# 某些文件系统（NFS、Cygwin/NTFS、容器 bind mount）会让 chmod 静默失效。
# 密钥文件变成他人可读是要命的事，所以实际回读一次而不是假定成功。
chmod_secret() {
  local __f="$1" __mode
  chmod 600 "$__f" 2>/dev/null || true
  __mode="$(stat -c '%a' "$__f" 2>/dev/null || stat -f '%Lp' "$__f" 2>/dev/null || echo '')"
  if [[ "$__mode" == "600" ]]; then
    ok "已写入 $__f（chmod 600）"
  elif [[ -n "$__mode" ]]; then
    warn "$__f 权限为 $__mode 而非 600 —— 本文件系统可能不支持 chmod"
    dim "如担心泄露，请手动确认该路径的访问权限"
  else
    ok "已写入 $__f（无法回读权限，请自行确认）"
  fi
}

# write_env_file <名字> KEY VALUE [KEY VALUE ...]
write_env_file() {
  local __name="$1"; shift
  local __file="$AGENT_ENV_DIR/${__name}.sh"

  if (( DRY_RUN )); then
    info "[dry-run] 写入凭据文件 $__file"
    return 0
  fi

  mkdir -p "$AGENT_ENV_DIR"
  {
    printf '# 由 agent-bootstrap 生成 —— 含密钥，请勿提交进版本库\n'
    printf '# agent: %s\n' "$__name"
    printf '# 生成于: %s\n' "$(date -Iseconds 2>/dev/null || date)"
    while (( $# >= 2 )); do
      printf 'export %s=%q\n' "$1" "$2"
      shift 2
    done
  } > "$__file"
  chmod_secret "$__file"
}

# ensure_path_entry <目录> —— 让该目录进入 PATH（幂等）
ensure_path_entry() {
  local __dir="$1"
  local __f="$AGENT_ENV_DIR/00-path.sh"

  if (( DRY_RUN )); then
    info "[dry-run] 确保 PATH 含 $__dir"
    return 0
  fi

  mkdir -p "$AGENT_ENV_DIR"
  touch "$__f"
  # 按生成行的形状匹配：`*":<dir>:"*`。别用 "$dir" —— 生成内容里引号
  # 从不紧贴目录名（有 `:"` 和 `:$PATH` 两种形态），那样永远匹配不到。
  if grep -qF "\":$__dir:\"" "$__f" 2>/dev/null; then
    return 0
  fi
  printf 'case ":$PATH:" in *":%s:"*) ;; *) PATH="%s:$PATH"; export PATH ;; esac\n' \
    "$__dir" "$__dir" >> "$__f"
  chmod 644 "$__f" 2>/dev/null || true
  ok "PATH 追加 $__dir（重开 shell 生效）"
}

# 在 ~/.bashrc 里注册 agent-env.d 的加载（幂等，用标记块识别）
ensure_env_sourced() {
  local __rc="$HOME/.bashrc"

  if (( DRY_RUN )); then
    info "[dry-run] 确保 $__rc 加载 $AGENT_ENV_DIR"
    return 0
  fi

  if [[ -f "$__rc" ]] && grep -qF "$ENV_MARKER_BEGIN" "$__rc"; then
    return 0
  fi
  if ! touch "$__rc" 2>/dev/null; then
    warn "无法写入 $__rc —— 请手动在 shell 配置里加载 $AGENT_ENV_DIR/*.sh"
    return 0
  fi

  {
    printf '\n%s\n' "$ENV_MARKER_BEGIN"
    printf 'if [ -d "%s" ]; then\n' "$AGENT_ENV_DIR"
    printf '  for _ab_f in "%s"/*.sh; do\n' "$AGENT_ENV_DIR"
    printf '    [ -r "$_ab_f" ] && . "$_ab_f"\n'
    printf '  done\n'
    printf '  unset _ab_f\n'
    printf 'fi\n'
    printf '%s\n' "$ENV_MARKER_END"
  } >> "$__rc"
  ok "已在 ~/.bashrc 注册 agent-env.d 加载"
}
