param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:SourceRoot = $PSScriptRoot
$script:InstallRoot = Join-Path $env:LOCALAPPDATA 'CodexUsageHUD'
$script:PayloadFiles = @(
    'CodexUsageHUD.ps1',
    'Start-CodexUsageHUD.cmd',
    'README.md',
    'LICENSE'
)

Add-Type -AssemblyName PresentationFramework

function Show-Info {
    param([string]$Message)
    [void][System.Windows.MessageBox]::Show(
        $Message,
        'Codex Usage HUD 安装程序',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    )
}

function Show-ErrorMessage {
    param([string]$Message)
    [void][System.Windows.MessageBox]::Show(
        $Message,
        'Codex Usage HUD 安装失败',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
}

function Confirm-YesNo {
    param([string]$Message)
    $result = [System.Windows.MessageBox]::Show(
        $Message,
        'Codex Usage HUD 安装程序',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    return $result -eq [System.Windows.MessageBoxResult]::Yes
}

function Confirm-RetryCancel {
    param([string]$Message)
    $result = [System.Windows.MessageBox]::Show(
        $Message,
        'Codex Usage HUD 登录检查',
        [System.Windows.MessageBoxButton]::RetryCancel,
        [System.Windows.MessageBoxImage]::Warning
    )
    return $result -eq [System.Windows.MessageBoxResult]::Retry
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$CommandPath,
        [string[]]$Arguments = @()
    )

    try {
        $output = & $CommandPath @Arguments 2>&1 | Out-String
        return [pscustomobject]@{
            Success = $LASTEXITCODE -eq 0
            ExitCode = $LASTEXITCODE
            Output = $output.Trim()
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            ExitCode = -1
            Output = $_.Exception.Message
        }
    }
}

function Test-CodexCli {
    param([Parameter(Mandatory = $true)][string]$CommandPath)

    if (-not (Test-Path -LiteralPath $CommandPath -PathType Leaf)) { return $false }
    $version = Invoke-ExternalCommand -CommandPath $CommandPath -Arguments @('--version')
    if (-not $version.Success) { return $false }
    $appServer = Invoke-ExternalCommand -CommandPath $CommandPath -Arguments @('app-server', '--help')
    return $appServer.Success
}

function Find-CodexCli {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_USAGE_HUD_CODEX)) {
        $candidates.Add($env:CODEX_USAGE_HUD_CODEX)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $candidates.Add((Join-Path $env:APPDATA 'npm\codex.cmd'))
    }
    @(Get-Command codex -All -ErrorAction SilentlyContinue) | ForEach-Object {
        $path = if (-not [string]::IsNullOrWhiteSpace($_.Path)) { $_.Path } else { $_.Source }
        if (-not [string]::IsNullOrWhiteSpace($path)) { $candidates.Add($path) }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not $seen.Add($candidate)) { continue }
        if (Test-CodexCli -CommandPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Find-NpmCommand {
    $commands = @(
        (Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1),
        (Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1)
    )
    foreach ($command in $commands) {
        if ($null -eq $command) { continue }
        $path = if (-not [string]::IsNullOrWhiteSpace($command.Path)) { $command.Path } else { $command.Source }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ([IO.Path]::GetExtension($path) -eq '.ps1') {
            $cmdPath = [IO.Path]::ChangeExtension($path, '.cmd')
            if (Test-Path -LiteralPath $cmdPath -PathType Leaf) { return $cmdPath }
        }
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    return $null
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = "$machinePath;$userPath"
}

function Ensure-Npm {
    $npm = Find-NpmCommand
    if ($null -ne $npm) { return $npm }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $winget) {
        throw '未检测到 npm 或 winget。请先安装 Node.js LTS，然后重新运行安装程序。'
    }
    if (-not (Confirm-YesNo '未检测到 Node.js/npm。是否通过 winget 下载并安装 Node.js LTS？')) {
        throw '已取消 Node.js 安装。'
    }

    Write-Output '正在通过 winget 安装 Node.js LTS...'
    $result = Invoke-ExternalCommand -CommandPath $winget.Source -Arguments @(
        'install', '--id', 'OpenJS.NodeJS.LTS', '--exact', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements'
    )
    if (-not $result.Success) {
        throw "Node.js 安装失败：$($result.Output)"
    }
    Refresh-ProcessPath
    $npm = Find-NpmCommand
    if ($null -eq $npm) {
        throw 'Node.js 安装完成，但当前进程仍未找到 npm。请重新打开安装程序。'
    }
    return $npm
}

function Install-CodexCli {
    $npm = Ensure-Npm
    Write-Output '正在通过 npm 下载并安装官方 Codex CLI...'
    $result = Invoke-ExternalCommand -CommandPath $npm -Arguments @('install', '-g', '@openai/codex')
    if (-not $result.Success) {
        throw "Codex CLI 安装失败：$($result.Output)"
    }
    Refresh-ProcessPath
    $cli = Find-CodexCli
    if ($null -eq $cli) {
        throw 'Codex CLI 已完成安装，但 --version 或 app-server --help 验证失败。'
    }
    return $cli
}

function Copy-HudPayload {
    [void](New-Item -ItemType Directory -Path $script:InstallRoot -Force)
    foreach ($fileName in $script:PayloadFiles) {
        $source = Join-Path $script:SourceRoot $fileName
        $destination = Join-Path $script:InstallRoot $fileName
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "安装包缺少文件：$fileName"
        }
        [IO.File]::Copy($source, $destination, $true)
    }
}

function Write-CodexPathConfig {
    param([Parameter(Mandatory = $true)][string]$CliPath)
    $configPath = Join-Path $script:InstallRoot 'codex-path.txt'
    [IO.File]::WriteAllText($configPath, $CliPath, (New-Object Text.UTF8Encoding($false)))
}

function Test-HudConnection {
    param([Parameter(Mandatory = $true)][string]$CliPath)

    $previousCliPath = $env:CODEX_USAGE_HUD_CODEX
    try {
        $env:CODEX_USAGE_HUD_CODEX = $CliPath
        $hudScript = Join-Path $script:InstallRoot 'CodexUsageHUD.ps1'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hudScript -ConnectionTest 2>&1 | Out-String
        return [pscustomobject]@{
            Success = $LASTEXITCODE -eq 0
            Output = $output.Trim()
        }
    } finally {
        $env:CODEX_USAGE_HUD_CODEX = $previousCliPath
    }
}

function Test-CliLoginStatus {
    param([Parameter(Mandatory = $true)][string]$CliPath)
    return Invoke-ExternalCommand -CommandPath $CliPath -Arguments @('login', 'status')
}

function Ensure-ChatGptAuthentication {
    param([Parameter(Mandatory = $true)][string]$CliPath)

    $connection = Test-HudConnection -CliPath $CliPath
    if ($connection.Success) { return }

    $loginStatus = Test-CliLoginStatus -CliPath $CliPath
    if (-not $loginStatus.Success) {
        $runCliLogin = Confirm-YesNo @'
HUD 使用独立的官方 Codex CLI 读取额度。

Codex Desktop 已登录，不代表独立 CLI 已经登录。安装程序接下来会打开 OpenAI 官方浏览器授权页面，请使用同一个 ChatGPT 账号完成登录。

此流程不需要 API Key，安装程序不会读取或保存登录令牌。

是否现在开始登录？
'@
        if (-not $runCliLogin) { throw '已取消 Codex CLI 登录。' }

        & $CliPath login
        if ($LASTEXITCODE -ne 0) { throw 'Codex CLI 登录流程未成功完成。' }
        $loginStatus = Test-CliLoginStatus -CliPath $CliPath
        if (-not $loginStatus.Success) {
            throw "Codex CLI 登录完成后仍未检测到登录状态：$($loginStatus.Output)"
        }
    }

    $connection = Test-HudConnection -CliPath $CliPath
    if ($connection.Success) { return }

    $retry = Confirm-RetryCancel @'
Codex CLI 已登录，但暂时无法读取额度。

请确认网络和代理能够访问 ChatGPT/OpenAI，然后点击“重试”。
'@
    if (-not $retry) { throw "Codex 额度连接验证失败：$($connection.Output)" }

    $connection = Test-HudConnection -CliPath $CliPath
    if (-not $connection.Success) { throw "重试后仍无法读取额度：$($connection.Output)" }
}

function New-HudShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = $script:InstallRoot
    $shortcut.Description = 'Codex Usage HUD'
    $shortcut.Save()
}

function Install-HudShortcuts {
    $launcher = Join-Path $script:InstallRoot 'Start-CodexUsageHUD.cmd'
    $startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Usage HUD.lnk'
    $programsShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Usage HUD.lnk'
    New-HudShortcut -ShortcutPath $startupShortcut -TargetPath $launcher
    New-HudShortcut -ShortcutPath $programsShortcut -TargetPath $launcher
}

try {
    foreach ($fileName in $script:PayloadFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:SourceRoot $fileName) -PathType Leaf)) {
            throw "安装包缺少文件：$fileName"
        }
    }
    if ($SelfTest) {
        Write-Output 'PASS: installer payload validation'
        exit 0
    }

    Write-Output '正在检测可独立运行的 Codex CLI...'
    $cliPath = Find-CodexCli
    if ($null -eq $cliPath) {
        $cliPath = Install-CodexCli
    } else {
        Write-Output "已检测到可用 Codex CLI：$cliPath"
    }

    Copy-HudPayload
    Write-CodexPathConfig -CliPath $cliPath
    Ensure-ChatGptAuthentication -CliPath $cliPath
    Install-HudShortcuts

    $launcher = Join-Path $script:InstallRoot 'Start-CodexUsageHUD.cmd'
    Start-Process -FilePath $launcher -WorkingDirectory $script:InstallRoot -WindowStyle Hidden
    Show-Info "安装完成。`n`n安装位置：$script:InstallRoot`n已创建当前用户的开机自启动快捷方式。"
    exit 0
} catch {
    Show-ErrorMessage $_.Exception.Message
    Write-Error $_.Exception.Message
    exit 1
}
