$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'CodexUsageHUD.ps1'
$installerPath = Join-Path $projectRoot 'Install-CodexUsageHUD.ps1'
$fakeServer = Join-Path $PSScriptRoot 'fake-codex-app-server.cmd'

foreach ($path in @($scriptPath, $installerPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        throw ($errors | Out-String)
    }
}
Write-Output 'PASS: PowerShell syntax'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SelfTest
if ($LASTEXITCODE -ne 0) {
    throw "SelfTest failed with exit code $LASTEXITCODE"
}

$previousCodexPath = $env:CODEX_USAGE_HUD_CODEX
try {
    $env:CODEX_USAGE_HUD_CODEX = $fakeServer
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -RpcSelfTest
    if ($LASTEXITCODE -ne 0) {
        throw "RpcSelfTest failed with exit code $LASTEXITCODE"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ConnectionTest
    if ($LASTEXITCODE -ne 0) {
        throw "ConnectionTest failed with exit code $LASTEXITCODE"
    }
} finally {
    $env:CODEX_USAGE_HUD_CODEX = $previousCodexPath
}

& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $installerPath -SelfTest
if ($LASTEXITCODE -ne 0) {
    throw "Installer SelfTest failed with exit code $LASTEXITCODE"
}

& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $scriptPath -Demo -SmokeTest
if ($LASTEXITCODE -ne 0) {
    throw "SmokeTest failed with exit code $LASTEXITCODE"
}

$macRoot = Join-Path $projectRoot 'macos'
$macFiles = @(
    (Join-Path $macRoot 'Sources\CodexUsageHUD\main.swift'),
    (Join-Path $macRoot 'App\Info.plist'),
    (Join-Path $macRoot 'build-macos.sh'),
    (Join-Path $macRoot 'README.md')
)
foreach ($path in $macFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing macOS package file: $path"
    }
    if ([IO.File]::ReadAllBytes($path) -contains 13) {
        throw "macOS file contains CRLF line endings: $path"
    }
}
[void][xml]([IO.File]::ReadAllText((Join-Path $macRoot 'App\Info.plist')))
$macContent = ($macFiles | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n"
if ($macContent -match '(?i)auth\.json|access[_ -]?token|chatgpt\.com/backend|api\.openai\.com|C:\\Users\\|D:\\A-Vibe') {
    throw 'macOS package contains a forbidden credential, internal endpoint, or local user path.'
}
foreach ($required in @(
    'account/rateLimits/read', 'windowDurationMins', '10_080',
    'CODEX_USAGE_HUD_CODEX', '/Applications/ChatGPT.app',
    'Applications/ChatGPT.app', '--version', 'app-server', '--help',
    '未找到 ChatGPT macOS 客户端，请先安装并登录 ChatGPT。',
    '无法连接 Codex，请确认 ChatGPT macOS 客户端已经登录。',
    'private let delegate = AppDelegate()'
)) {
    if ($macContent -notmatch [regex]::Escape($required)) {
        throw "macOS package is missing required behavior: $required"
    }
}
$macSource = [IO.File]::ReadAllText((Join-Path $macRoot 'Sources\CodexUsageHUD\main.swift'))
if ($macSource -match 'AppServerClient\(\)\.readUsage\(\)') {
    throw 'macOS source does not retain AppServerClient during readUsage().' 
}
if ($macSource -match '(?i)@openai/codex|npm\s+install|LaunchAgents|launchctl') {
    throw 'macOS runtime source still contains CLI installation or LaunchAgent behavior.'
}
foreach ($removed in @('Install-CodexUsageHUD.command', 'Uninstall-CodexUsageHUD.command')) {
    if (Test-Path -LiteralPath (Join-Path $macRoot $removed)) {
        throw "Obsolete macOS user installer still exists: $removed"
    }
}
Write-Output 'PASS: macOS package static validation'

Write-Output 'PASS: all project checks'
