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

- 收起时只显示 5 小时和每周剩余百分比；没有 5 小时窗口时显示 `--%`。
- 鼠标移入后展开详细信息，移出后恢复胶囊。
- 每 5 分钟自动刷新；双击胶囊或通过菜单栏可立即刷新。
- 拖动、展开、收起和重新显示后，均以收起胶囊为锚点限制在当前显示器可见区域。

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

发布前至少验证：

- App 能在 `/Applications` 中直接打开。
- 能找到 `/Applications/ChatGPT.app/Contents/Resources/codex`。
- ChatGPT 已登录时能读取用量。
- 未安装 ChatGPT 和未登录时分别显示正确提示。
- 胶囊悬停、拖动、多显示器边界和菜单栏操作正常。

代码尚未在 macOS 上编译和验证，需要在 Mac 上完成最终构建测试。
