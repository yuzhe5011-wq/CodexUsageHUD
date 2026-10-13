# Codex Usage HUD 2.0

一个只针对 Codex 的 Windows 置顶悬浮条，显示：

- 5 小时额度剩余百分比和重置倒计时
- 每周额度剩余百分比和重置倒计时
- 可用重置卡数量
- Codex 提供时，显示最近一张可用重置卡的到期时间

## 2.0 的数据来源

HUD 启动本机官方 `codex app-server`，通过其 JSONL 协议调用 `account/rateLimits/read`。工具不再读取 `%USERPROFILE%\.codex\auth.json`，不会接触或保存 access token，也不会直接调用 ChatGPT 内部 Web 接口。

OpenAI 官方 app-server 文档：<https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md>

## 下载与发布包

普通用户应从 GitHub Releases 下载对应平台的 ZIP，而不是直接运行开发目录：

- Windows：解压后运行 `Install-CodexUsageHUD.cmd`，安装程序会检测或按确认下载官方 Codex CLI。
- macOS：下载已经在 Mac 上构建的 `CodexUsageHUD.app.zip`，解压后将 App 拖入“应用程序”。

仓库中的 GitHub Actions 会在推送 `v*` 标签时构建 Windows 和 macOS 包。macOS 包默认未签名/公证，正式面向公众发布前应由维护者完成 Apple Developer 签名和公证。

## 要求

- Windows 10 或 Windows 11
- 直接运行源码时，需要已安装并登录 Codex CLI
- `codex` 命令能够在普通 PowerShell 中运行

从发布包安装时，安装程序会先检测现有 CLI；只有在用户确认后，才会通过 npm 或 winget 下载缺少的依赖。

检查：

```powershell
codex --version
codex app-server --help
```

如果只有 Codex Desktop，而它内置的 `codex.exe` 无法由外部程序启动，请另外安装官方 Codex CLI。通过 npm 安装时可使用：

```powershell
npm install -g @openai/codex
```

需要指定其他 Codex CLI 路径时，可在启动前设置：

```powershell
$env:CODEX_USAGE_HUD_CODEX = 'C:\path\to\codex.exe'
```

## 常见问题

- **提示找不到 Codex CLI**：在普通 PowerShell 中确认 `codex --version` 和 `codex app-server --help` 都成功，再重新运行安装程序。
- **提示未登录或额度连接失败**：独立 Codex CLI 的登录状态可能与 ChatGPT Desktop 不同。按安装程序提示完成“使用 ChatGPT 登录”，并确认代理允许 Codex 访问服务。
- **刷新失败**：程序会保留上一次成功读取的数值；只有成功返回新的用量数据时才会更新界面。完全空的 app-server 响应会按失败处理。
- **没有重置卡**：这是有效状态，不是错误；最近到期会显示“— / 没有可用卡”。如果服务没有返回重置卡字段，会显示“不可用”。

## 隐私与安全

程序只通过本机官方 `codex app-server` 读取额度，不读取或保存 `%USERPROFILE%\.codex\auth.json`，不记录 access token，也不直接调用 ChatGPT 内部 Web 接口。请勿把运行日志、认证文件或代理配置提交到仓库。

## 启动

双击 `Start-CodexUsageHUD.cmd`。

## 在其他电脑上一键安装

解压发布包后，双击 `Install-CodexUsageHUD.cmd`。安装程序不会携带 Codex CLI、Node.js 或任何凭据，它会：

1. 实际运行 `codex --version` 和 `codex app-server --help`，优先复用电脑上已有的独立 Codex CLI。
2. 没有可用 CLI 时，通过 npm 执行 `npm install -g @openai/codex`。
3. 没有 npm 时，经用户确认后通过 winget 安装 Node.js LTS，再下载 Codex CLI。
4. 检查独立 CLI 的 `codex login status`；即使 Desktop 已登录，独立 CLI 未登录时也会明确说明差异，并启动 OpenAI 官方浏览器授权页面。
5. 登录后通过 `account/rateLimits/read` 验证额度连接；网络或代理异常时提供重试提示。
6. 安装 HUD 到 `%LOCALAPPDATA%\CodexUsageHUD`，创建开始菜单及当前用户开机自启动快捷方式，然后启动 HUD。

独立 CLI 使用“通过 ChatGPT 登录”，可以选择与 Desktop 相同的 ChatGPT 账号，不需要 API Key。安装程序不会读取、记录或复制 token。

## 项目结构

```text
CodexUsageHUD/
├─ CodexUsageHUD.ps1
├─ Start-CodexUsageHUD.cmd
├─ Install-CodexUsageHUD.ps1
├─ Install-CodexUsageHUD.cmd
├─ build-windows-release.ps1
├─ README.md
├─ LICENSE
├─ SECURITY.md
├─ CONTRIBUTING.md
├─ macos/
└─ tests/
   ├─ Test-CodexUsageHUD.ps1
   └─ fake-codex-app-server.*
```

macOS 源码和构建说明见 [`macos/README.md`](macos/README.md)。

统一运行项目检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexUsageHUD.ps1
```

## 操作

- 拖动悬浮条：按住任意空白位置拖动。
- 立即刷新：双击悬浮条，或在托盘菜单选择“立即刷新”。
- 鼠标穿透：在托盘菜单勾选“鼠标穿透”；从托盘菜单取消勾选即可恢复。
- 隐藏/显示：使用托盘菜单切换，或双击托盘图标恢复显示。
- 自动刷新：每 2 分钟一次。
- 运行日志：`%LOCALAPPDATA%\CodexUsageHUD\CodexUsageHUD.log`。日志记录启动、刷新、窗口关闭和异常信息，并会过滤常见凭据字段；排查突然退出时可提供该文件。若该目录不可写，会退回 `%TEMP%\CodexUsageHUD\CodexUsageHUD.log`。

出现突然退出时，先重新启动并复现一次，再提供日志末尾内容：有 `Window closed` 或 `Fatal startup/UI exception` 表示应用记录到了关闭/异常；如果日志停在刷新中且没有关闭记录，通常表示进程被系统或其他程序终止。

## 演示模式

不启动 Codex、不读取账号、不联网，以模拟数据查看界面：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\CodexUsageHUD.ps1 -Demo
```

## 字段缺失处理

`account/rateLimits/read` 的公开字段包括用量窗口、重置时间和可用重置卡数量。不同 Codex 版本不一定返回每张重置卡的到期明细：

- 返回数量和到期明细：显示最近到期时间。
- 只返回数量：显示数量，并标注“当前 Codex 未返回到期时间”。
- 不返回重置卡字段：显示“不可用”，不把未知值伪装成 0。

重置卡仅展示，不提供消耗操作，避免误触。

## 项目说明

交互思路受 Win-CodexBar 和 WindexBar 启发；本实现为独立的 PowerShell/WPF 代码，没有复制这两个项目的源代码。
