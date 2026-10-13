# Contributing

## Before opening a pull request

Run the Windows project checks from PowerShell 5.1 or later:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexUsageHUD.ps1
```

For macOS source changes, build and run the package self-test on macOS:

```bash
cd macos
bash ./build-macos.sh
```

Keep changes focused. Do not add direct ChatGPT web API calls, access-token
handling, or a bundled Codex CLI. Changes to the PowerShell files must remain
compatible with Windows PowerShell 5.1.

## Pull requests

Describe the user-visible change, the platforms checked, and any limitations
that could not be tested locally. Never attach authentication files, raw
access tokens, or unredacted logs.
