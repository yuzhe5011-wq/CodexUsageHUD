# Codex Usage HUD for macOS

macOS 12 及以上版本的原生菜单栏与悬浮胶囊版本。它通过 ChatGPT macOS 客户端自带的 `codex app-server` 只读获取用量，不读取登录文件，也不要求普通用户另外安装 Codex CLI。

## 普通用户安装

发布者应提供已经在 Mac 上构建完成的 `CodexUsageHUD.app` ZIP 包。

1. 安装并登录 ChatGPT macOS 客户端。
2. 解压 `CodexUsageHUD.app`。
3. 将 App 拖入“应用程序”文件夹并打开。

普通用户不需要运行安装脚本，不需要安装 Xcode、Swift、Node.js、npm 或独立 Codex CLI。本项目不会创建 LaunchAgent，也不会自动设置登录启动。

首次打开时：

- 没有安装 ChatGPT.app：显示“未找到 ChatGPT macOS 客户端，请先安装并登录 ChatGPT。”
- 无法读取 Codex 用量：显示“无法连接 Codex，请确认 ChatGPT macOS 客户端已经登录。”

## 功能

- 收起时显示 5 小时和每周剩余百分比及对应的剩余额度条；没有 5 小时窗口时显示 `--%`。
- 鼠标移入后展开详细信息，移出后恢复胶囊。
- 每 2 分钟自动刷新；双击胶囊或通过菜单栏可立即刷新。
- 同一用户只运行一个实例；从不同目录启动另一份 App 时，新实例会自动退出。
- 拖动、展开、收起和重新显示后，均以收起胶囊为锚点限制在当前显示器可见区域。

如果 app-server 返回完全空的用量结果，程序按刷新失败处理并保留上一次成功数据。账户没有重置卡时显示“— / 没有可用卡”；服务未返回重置卡字段时显示“不可用”。

## 开发者构建

以下步骤只供负责预编译发布包的开发者使用，必须在 macOS 上执行：

```bash
cd macos
bash ./build-macos.sh
```

构建结果：

```text
macos/build/CodexUsageHUD.app
```

在 Mac 上完成实际运行验证后，可生成供普通用户解压的 ZIP：

```bash
ditto -c -k --sequesterRsrc --keepParent \
  ./build/CodexUsageHUD.app \
  ./CodexUsageHUD-macOS.zip
```

构建脚本生成的是未签名 App。面向其他用户发布前，维护者应使用 Apple Developer 证书完成签名，并使用 `notarytool` 公证，否则 macOS Gatekeeper 可能要求用户手动允许首次打开。

如果本机已配置签名身份，可在构建时传入 `CODESIGN_IDENTITY`：

```bash
CODESIGN_IDENTITY="Developer ID Application: Example" bash ./build-macos.sh
```

发布前至少验证：

- App 能在 `/Applications` 中直接打开。
- 能找到 ChatGPT 内置的 `codex` 命令（兼容 `Contents/Resources/codex` 与 `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex` 两种布局）。
- ChatGPT 已登录时能读取用量。
- 未安装 ChatGPT 和未登录时分别显示正确提示。
- 胶囊悬停、拖动、多显示器边界和菜单栏操作正常。

`build-macos.sh` 会生成支持 Apple Silicon 和 Intel Mac 的通用 App，并将最低系统版本设为 macOS 12。仓库维护者已在 Apple Silicon Mac 上完成构建、用量读取连接测试和界面启动验证。Intel Mac 与 macOS 12 的实际运行仍需在对应设备上验证。
