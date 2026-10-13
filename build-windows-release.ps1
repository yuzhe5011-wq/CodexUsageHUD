param(
    [string]$Version = 'dev'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$safeVersion = $Version -replace '[^0-9A-Za-z._-]', '-'
$buildRoot = Join-Path $root 'build'
$stageRoot = Join-Path $buildRoot 'CodexUsageHUD-Windows'
$archive = Join-Path $buildRoot ("CodexUsageHUD-Windows-{0}.zip" -f $safeVersion)

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $archive) {
    Remove-Item -LiteralPath $archive -Force
}
[void](New-Item -ItemType Directory -Path $stageRoot -Force)

foreach ($fileName in @(
    'CodexUsageHUD.ps1',
    'Install-CodexUsageHUD.ps1',
    'Install-CodexUsageHUD.cmd',
    'Start-CodexUsageHUD.cmd',
    'README.md',
    'LICENSE'
)) {
    $source = Join-Path $root $fileName
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing release file: $fileName"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $stageRoot $fileName) -Force
}

Compress-Archive -Path (Join-Path $stageRoot '*') -DestinationPath $archive -CompressionLevel Optimal
Write-Output "Created $archive"
