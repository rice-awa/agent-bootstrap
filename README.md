# agent-bootstrap

给云端 Linux 开发机装 Claude Code 和 Codex，顺便把配置铺好。

装过的就不动，没装的自动装。跑几遍都没事。

## 怎么用

云上直接一行，不需要任何凭证：

```bash
curl -fsSL https://raw.githubusercontent.com/rice-awa/agent-bootstrap/main/bootstrap.sh | bash -s -- --all
```

它会先把仓库打成 tar 包下到临时目录（走 codeload 这个 CDN，不通再退回 `git clone`）再交给自己跑。为什么要多这一步：管道执行时 stdin 是脚本本身，同目录的 `lib/` 和 `agents/` 拿不到，所以得有个完整的副本。优先走 tar 包是因为不少网络策略放行 GitHub 的 CDN 却拦 `github.com` 本体，而 `git clone` 打的正是后者。

也可以先 clone 再用：

```bash
git clone https://github.com/rice-awa/agent-bootstrap.git
cd agent-bootstrap
./bootstrap.sh --all
```

fork 之后想用自己的仓库，把地址覆盖掉：

```bash
YOUR=你的用户名
AGENT_BOOTSTRAP_REPO="https://github.com/${YOUR}/agent-bootstrap.git" \
  curl -fsSL "https://raw.githubusercontent.com/${YOUR}/agent-bootstrap/main/bootstrap.sh" \
  | bash -s -- --all
```

## 参数

| 参数 | 作用 |
|---|---|
| `-a, --agent LIST` | 只处理指定的，逗号分隔，比如 `claude,codex` |
| `--all` | 全都处理 |
| `-i, --install-only` | 只装 CLI，跳过配置与 Key 收集 |
| `-y, --non-interactive` | 不提问，只用环境变量。CI 里用这个 |
| `-f, --force` | 覆盖你手改过的配置文件（覆盖前会备份） |
| `-n, --dry-run` | 只打印要干什么，不真写 |
| `--verify` | 装完发一次探测请求验证连通与认证。**默认不发**，见下节 |
| `--skip-verify` | 兼容旧用法，等同默认行为（不探测） |
| `-l, --list` | 看看支持哪些 agent |

## 它干三件事

1. **装工具**：`claude`、`codex`，已经有了就跳过
2. **铺配置**：把 `configs/` 里的东西复制到你的 home 目录
3. **收集 API Key**：问你或者从环境变量拿，然后写进配置文件

加 `--install-only` 就只干第 1 件，配置和 Key 都不碰。

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

## 连通性探测（默认关闭）

装完**默认一个请求都不发**。探测只换来"端点通不通"这一点信息，代价却不对称：请求头跟真实客户端不一致时，部分中转（带渠道健康策略的）会把探测判成异常流量并**停用渠道**，连累所有正在用的客户端。想看通不通，显式加 `--verify`。

开了 `--verify` 之后，探测按下面三条来，避免给出错误结论：

- **User-Agent 按真实客户端来** —— `claude-cli/<本地版本> (external, cli)`。不少中转要求 UA 以 `claude-cli/` 开头，否则停用渠道。Codex 侧的要求没测出来，默认沿用 curl 自带的 UA，可用 `CODEX_PROBE_UA` 覆盖。
- **不只看状态码，还看响应体** —— 网关/WAF 对未知路径常回 `200 + HTML 首页`。把它当成功是最坏的结果：你以为配好了，真实客户端却报 `malformed response`。所以 200 必须响应体是 JSON 才算通过；判断类型按内容而不是 `Content-Type`（实测有网关用 `text/plain` 返回合法 JSON）。
- **区分"路径不存在"和"上游挂了"** —— 5xx 说明端点存在、上游不可用，提示你稍后重试，而不是让你去改 `base_url`。

## 探测能替你答的两个问题

这两条以前靠猜，现在 `--verify` 会直接给结论。没跑过真实中转和真实 Codex 端点（抓官方文档时被网络策略拦了），但每条分支都用本地 mock 服务器验过（JSON 200 / HTML 200 / 400 / 401 / 5xx / 404 / 连不上）：

1. **`wire_api = "responses"` 还是 `"chat"`** —— 先试 `/responses`，不通再试 `/chat/completions`，然后告诉你改 `config.toml` 里的哪个字段。很多中转只有 `/chat/completions`。
2. **`base_url` 要不要带 `/v1`** —— Claude 侧 `/v1/messages` 和 `/messages` 都试；Codex 侧会在原 `base_url` 上补 `/v1` 再试一次，通了就告诉你怎么改。

至于 Claude 的登录凭证到底在 `~/.claude/.credentials.json` 还是 `~/.claude.json` —— 脚本不猜，两个位置都探一遍再如实报告。都没有，就说明你在用 `settings.json` 的 env 认证（本仓库推荐的方式），不需要登录。

## 依赖

- bash 4.0+
- `curl`
- Node 22+ —— **只有 Codex 需要**。Claude Code 走官方安装脚本，不用 Node

## 换行符

shell 脚本必须是 LF 换行。仓库里带了 `.gitattributes` 帮你处理。如果你在 Windows 上编辑，注意别让编辑器写成 CRLF，否则 Linux 上会报 `\r: command not found` 这种莫名其妙的错。
