# agent-bootstrap

给云端 Linux 开发机装 Claude Code 和 Codex，顺便把配置铺好。

装过的就不动，没装的自动装。跑几遍都没事。

## 怎么用

```bash
./bootstrap.sh --all
```

不想先 clone，可以管道直接跑（得告诉它仓库在哪）：

```bash
AGENT_BOOTSTRAP_REPO=<你的仓库地址> \
  curl -fsSL <bootstrap.sh 的 raw 地址> | bash -s -- --all
```

## 参数

| 参数 | 作用 |
|---|---|
| `-a, --agent LIST` | 只处理指定的，逗号分隔，比如 `claude,codex` |
| `--all` | 全都处理 |
| `-y, --non-interactive` | 不提问，只用环境变量。CI 里用这个 |
| `-f, --force` | 覆盖你手改过的配置文件（覆盖前会备份） |
| `-n, --dry-run` | 只打印要干什么，不真写 |
| `--skip-verify` | 装完不测端点通不通 |
| `-l, --list` | 看看支持哪些 agent |

## 它干三件事

1. **装工具**：`claude`、`codex`，已经有了就跳过
2. **铺配置**：把 `configs/` 里的东西复制到你的 home 目录
3. **收集 API Key**：问你或者从环境变量拿，然后写进配置文件

## API Key 从哪来

按这个顺序找，找到就停：

1. **环境变量里已经有了** → 直接用，不问你
2. **没有，但能交互** → 问你要（输 Key 的时候不显示）
3. **没有，又加 `--non-interactive`** → 有默认值的用默认值，没默认值的直接报错退出

第 3 条是故意的。宁可报错，也不能悄悄用一个空的 Key 把配置写坏。

> 脚本经常是 `curl | bash` 跑的，这时候标准输入是脚本本身。所以所有提问都从 `/dev/tty` 读，不然会把脚本文本当成你的输入吃掉。

## 文件都写到哪

| 位置 | 是什么 |
|---|---|
| `~/.claude/settings.json` | Claude Code 配置，**里面有 API Key**，权限 600 |
| `~/.claude/CLAUDE.md` | 你的全局提示，从 `configs/claude/CLAUDE.md` 复制 |
| `~/.codex/config.toml` | Codex 配置，由 `configs/codex/config.toml.tmpl` 生成，**不含 Key** |
| `~/.codex/auth.json` | Codex 的 Key，**里面有 API Key**，权限 600 |
| `~/.config/agent-env.d/00-path.sh` | 往 PATH 里加 `~/.local/bin`，由 `~/.bashrc` 自动加载 |

**刻意不碰的**：`~/.claude.json`、`~/.claude/.credentials.json`、两边的 session 历史。这些是登录状态和本机记录，碰了会出乱子。

每个 `.last-deployed` 后缀的文件是"上次写进去的副本"，用来判断你有没有手改过，不用管它。

## 关于 API Key 放哪

两个工具不一样，位置都是各自定了的，不是随便挑的：

- **Claude Code** → `~/.claude/settings.json` 的 `env` 字段。它支持这个字段，会把里面的键值注入运行时环境，所以 Base URL、Key、模型名都写这儿，不用改 shell profile。
- **Codex** → `~/.codex/auth.json`。因为配置里写了 `requires_openai_auth = true`，这条路径读的是 auth.json 里的 `OPENAI_API_KEY`，长这样：

  ```json
  { "OPENAI_API_KEY": "sk-..." }
  ```

  所以 `config.toml` 是干净的，不带 Key。

提交进 git 的只有 `configs/` 里的**模板**（占位符，没有真实值）。真实的 `settings.json` 和 `auth.json` 只在你机器上，权限 600。它们的 `.last-deployed` 副本里也有 Key，所以副本同样按 600 处理。

## 改配置

- **改默认值**（比如模型名）→ 改 `configs/` 里的 `.tmpl` 文件，然后重跑
- **临时改这台机器** → 直接改 `~/.claude/settings.json`。脚本发现你改过就会跳过，不会覆盖
- **一定要用模板覆盖** → 加 `--force`，会先备份

覆盖规则：

| 情况 | 结果 |
|---|---|
| 文件不存在 | 直接写 |
| 内容和上次一样 | 不备份，静默刷新 |
| 模板变了、你没手改过 | 自动更新 |
| **你手改过** | **跳过**，提示加 `--force` |
| 加 `--force` | 先备份再覆盖 |

## 加一个新的 agent

复制 `agents/_template.sh`，填三个函数就行，`bootstrap.sh` 不用改：

- `agent_install` — 怎么装
- `agent_configure` — 配置写哪、Key 怎么收
- `agent_verify` — 装完怎么检查

然后把名字加到 `bootstrap.sh` 里的 `KNOWN_AGENTS`。

## 模板怎么写

`configs/` 里 `.tmpl` 文件可以用两种占位符：

```
{{KEY}}         变量值，没设就是空
{{KEY|默认值}}   变量值，没设就用默认值
```

默认值刻意写在**模板文件里**而不是 shell 代码里 —— 这样打开模板就知道哪些是默认值、哪些要你填。

## ⚠️ 还没在真机验证过的地方

这几条没实机跑过（抓官方文档时被网络策略拦了）。脚本已经把它们做成了**自动探测 + 具体建议**，第一次跑就会告诉你哪里不对：

1. **`wire_api = "responses"`** —— 要求你的中转支持 `/responses` 接口。很多中转只有 `/chat/completions`，那就要改成 `wire_api = "chat"`。脚本会自己回退探测，然后告诉你改哪个字段。

2. **`base_url` 要不要带 `/v1`** —— Codex 是往 `{base_url}/responses` 发，Claude 是往 `{base_url}/v1/messages` 发，规则不一样。脚本会把两种路径都试一遍再下结论。

另外，Linux 下 Claude 的登录凭证到底在 `~/.claude/.credentials.json` 还是 `~/.claude.json` 里，两种说法我都见过。第一次登录后 `ls -la ~/.claude*` 看一眼就知道了。

## 依赖

- bash 4.0+
- `curl`
- Node 22+ —— **只有 Codex 需要**。Claude Code 走官方安装脚本，不用 Node

## 换行符

shell 脚本必须是 LF 换行。仓库里带了 `.gitattributes` 帮你处理。如果你在 Windows 上编辑，注意别让编辑器写成 CRLF，否则 Linux 上会报 `\r: command not found` 这种莫名其妙的错。
