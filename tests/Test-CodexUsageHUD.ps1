$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'CodexUsageHUD.ps1'
$installerPath = Join-Path $projectRoot 'Install-CodexUsageHUD.ps1'
$releaseScriptPath = Join-Path $projectRoot 'build-windows-release.ps1'
$fakeServer = Join-Path $PSScriptRoot 'fake-codex-app-server.cmd'

foreach ($path in @($scriptPath, $installerPath, $releaseScriptPath)) {
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

$releaseArchive = Join-Path $projectRoot 'build\CodexUsageHUD-Windows-test.zip'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releaseScriptPath -Version test
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $releaseArchive -PathType Leaf)) {
    throw 'Windows release package build failed.'
}
Remove-Item -LiteralPath $releaseArchive -Force
Remove-Item -LiteralPath (Join-Path $projectRoot 'build\CodexUsageHUD-Windows') -Recurse -Force

# A second copy must exit before creating a WPF window, including from another path.
$instanceMutex = New-Object System.Threading.Mutex($false, 'Local\CodexUsageHUD.SingleInstance')
$ownsInstanceMutex = $false
$duplicateScript = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsageHUD-' + [guid]::NewGuid() + '.ps1')
try {
    $ownsInstanceMutex = $instanceMutex.WaitOne(0)
    if (-not $ownsInstanceMutex) { throw 'Close the running HUD before running the UI tests.' }
    Copy-Item -LiteralPath $scriptPath -Destination $duplicateScript
    $output = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $duplicateScript -Demo -SmokeTest
    if ($LASTEXITCODE -ne 0 -or $output -notcontains 'Codex Usage HUD is already running.' -or
        $output -contains 'PASS: WPF window loaded and rendered') {
        throw 'Duplicate HUD instance was not suppressed.'
    }
    Write-Output 'PASS: duplicate instance from another path exits before WPF startup'
} finally {
    if ($ownsInstanceMutex) { $instanceMutex.ReleaseMutex() }
    $instanceMutex.Dispose()
    Remove-Item -LiteralPath $duplicateScript -Force -ErrorAction SilentlyContinue
}

# After releasing the lock, the HUD must start and render normally.
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
    'private let refreshInterval: TimeInterval = 120',
    'hasUsableUsage', 'Codex app-server 返回了空的用量数据。',
    '当前 Codex 未返回到期时间',
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

foreach ($requiredPath in @(
    (Join-Path $projectRoot 'LICENSE'),
    (Join-Path $projectRoot 'SECURITY.md'),
    (Join-Path $projectRoot 'CONTRIBUTING.md'),
    (Join-Path $projectRoot 'CHANGELOG.md'),
    (Join-Path $projectRoot '.github\workflows\ci.yml'),
    (Join-Path $projectRoot '.github\workflows\release.yml'),
    (Join-Path $projectRoot '.github\ISSUE_TEMPLATE\bug_report.yml')
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Missing repository support file: $requiredPath"
    }
}
if (Test-Path -LiteralPath (Join-Path $projectRoot 'dist\README_20260713180501.md')) {
    throw 'Stale timestamped distribution README is still present.'
}
$releaseWorkflow = [IO.File]::ReadAllText((Join-Path $projectRoot '.github\workflows\release.yml'))
foreach ($requiredReleaseBehavior in @(
    'actions/download-artifact@v4',
    'merge-multiple: true',
    'contents: write',
    'gh release create',
    'CodexUsageHUD-macOS-*.zip.sha256'
)) {
    if ($releaseWorkflow -notmatch [regex]::Escape($requiredReleaseBehavior)) {
        throw "Release workflow is missing required behavior: $requiredReleaseBehavior"
    }
}
Write-Output 'PASS: public repository support files'

Write-Output 'PASS: all project checks'
