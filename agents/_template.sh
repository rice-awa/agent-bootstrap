#!/usr/bin/env bash
# agents/_template.sh — 新增 agent 时复制本文件，实现三个函数即可接入。
#
# 契约：
#   agent_install    幂等安装。已装则直接返回 0
#   agent_configure  渲染 / 软链配置，收集凭据并写环境变量文件
#   agent_verify     校验。发现问题用 warn 提示，不要 die
#
# 可直接使用的全局变量 / 函数：
#   BOOTSTRAP_DIR  FORCE  DRY_RUN  NON_INTERACTIVE  SKIP_VERIFY
#   have need die info ok warn err dim
#   ask confirm have_tty
#   bag_set render_to
#   install_rendered install_copy validate_json backup_file
#   write_env_file ensure_path_entry ensure_node probe_http chmod_secret

AGENT_NAME="${AGENT_NAME:-mytool}"

agent_install() {
  if have mytool; then
    ok "mytool 已安装"
    return 0
  fi
  info "安装 mytool"
  if (( DRY_RUN )); then
    info "[dry-run] <安装命令>"
    return 0
  fi
  die "尚未实现"
}

agent_configure() {
  # 1) 收集变量（默认值写在模板里，这里只收集真正需要用户提供的东西）
  # ask MYTOOL_BASE_URL "base_url" ""
  # bag_set BASE_URL "$MYTOOL_BASE_URL"

  # 2) 落盘（复制，不用软链；含密钥的文件加 --secret）
  # install_rendered "$BOOTSTRAP_DIR/configs/mytool/config.toml.tmpl" \
  #                  "$HOME/.mytool/config.toml"
  # install_copy "$BOOTSTRAP_DIR/configs/mytool/rules.md" "$HOME/.mytool/rules.md"

  # 3) 若该工具只能从环境变量读密钥，落一个 600 的 env 文件
  # write_env_file mytool MYTOOL_API_KEY "$MYTOOL_API_KEY"
  :
}

agent_verify() {
  if have mytool; then
    ok "mytool: $(mytool --version 2>/dev/null | head -n1)"
  else
    warn "mytool 不在 PATH 中"
  fi

  if (( SKIP_VERIFY )); then
    info "已跳过连通性探测（--skip-verify）"
    return 0
  fi
  :
}
