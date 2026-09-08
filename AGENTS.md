# Codex Usage HUD 项目约束

## 目标

这是一个 Windows PowerShell 5.1 / WPF 小工具，用置顶悬浮条只读展示 Codex 用量、重置时间和重置卡信息。

## 实现边界

- 保持单脚本、无第三方运行时依赖的结构，除非需求明确要求改变技术栈。
- 通过官方 `codex app-server` 的 JSONL 协议读取数据。
- 不读取 `%USERPROFILE%\.codex\auth.json`，不接触、记录或输出 access token。
- 不直接调用 ChatGPT 内部 Web 接口。
- 重置卡只展示，不提供消耗操作。
- 修改应保持外科手术式，不顺带重构无关代码。

## 兼容性

- 主程序必须兼容 Windows PowerShell 5.1。
- 含中文的 PowerShell 文件应保留 UTF-8 BOM，避免 Windows PowerShell 5.1 解码错误。

## 验证

完成代码修改后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexUsageHUD.ps1
```

测试应覆盖语法解析、数据解析、模拟 app-server JSONL 通信和 WPF 渲染冒烟检查。
