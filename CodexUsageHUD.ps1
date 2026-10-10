param(
    [switch]$Demo,
    [switch]$SelfTest,
    [switch]$SmokeTest,
    [switch]$RpcSelfTest,
    [switch]$ConnectionTest
)

$ErrorActionPreference = 'Stop'
$script:RefreshSeconds = 120
$script:RpcTimeoutMs = 12000
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = $env:LOCALAPPDATA }
if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = [IO.Path]::GetTempPath() }
$script:LogPath = Join-Path $localAppData 'CodexUsageHUD\CodexUsageHUD.log'
$script:LoggingAvailable = $false
$script:CloseReason = 'unknown'
$script:UnhandledExceptionHandler = $null
$script:DispatcherUnhandledExceptionHandler = $null

function Protect-LogText {
    param([AllowNull()][object]$Value)

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    # Keep diagnostics useful without ever persisting common credential formats.
    $text = $text -replace '(?i)\bBearer\s+[-A-Za-z0-9._~+/=]+', 'Bearer <redacted>'
    $text = $text -replace '(?i)\b(authorization|access[_ -]?token|refresh[_ -]?token|api[_ -]?key|password|cookie)\b\s*[:=]\s*("[^"]*"|''[^'']*''|[^,;\s]+)', '$1=<redacted>'
    $text = $text -replace '(?i)\bsk-[A-Za-z0-9_-]{10,}\b', '<redacted>'
    $text = $text -replace '\s+', ' '
    $text = $text.Trim()
    if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) + '…' }
    return $text
}

function Write-HudLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [AllowEmptyString()][string]$Message = ''
    )

    if (-not $script:LoggingAvailable -or [string]::IsNullOrWhiteSpace($script:LogPath)) { return }
    try {
        $safeMessage = Protect-LogText $Message
        $line = '{0} [{1}] pid={2} {3}{4}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff zzz'), $Level, $PID, $safeMessage, [Environment]::NewLine
        [IO.File]::AppendAllText($script:LogPath, $line, [Text.UTF8Encoding]::new($false))
    } catch {
        # Logging must never become a new reason for the HUD to exit.
    }
}

function Write-HudException {
    param(
        [Parameter(Mandatory = $true)][string]$Context,
        [AllowNull()]$Exception
    )

    try {
        $details = if ($Exception -is [Exception]) { $Exception.ToString() } else { [string]$Exception }
        Write-HudLog -Level ERROR -Message ('{0}: {1}' -f $Context, $details)
    } catch {
        # Keep exception reporting best-effort.
    }
}

function Initialize-HudLogging {
    $candidates = @(
        $script:LogPath,
        (Join-Path ([IO.Path]::GetTempPath()) 'CodexUsageHUD\CodexUsageHUD.log')
    ) | Select-Object -Unique

    foreach ($candidate in $candidates) {
        try {
            $directory = Split-Path -Parent $candidate
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                [IO.File]::WriteAllText($candidate, '', [Text.UTF8Encoding]::new($false))
            }
            $script:LogPath = $candidate
            $script:LoggingAvailable = $true
            return
        } catch {
            continue
        }
    }
    $script:LoggingAvailable = $false
}

function Register-ProcessDiagnostics {
    try {
        $script:UnhandledExceptionHandler = [UnhandledExceptionEventHandler]{
            param($sender, $eventArgs)
            try {
                Write-HudException -Context 'AppDomain.UnhandledException' -Exception $eventArgs.ExceptionObject
            } catch {
            }
        }
        [AppDomain]::CurrentDomain.add_UnhandledException($script:UnhandledExceptionHandler)
    } catch {
        Write-HudException -Context 'Register AppDomain.UnhandledException failed' -Exception $_.Exception
    }
}

Initialize-HudLogging
$startupMode = if ($Demo) { 'demo' } elseif ($SelfTest) { 'self-test' } elseif ($RpcSelfTest) { 'rpc-self-test' } elseif ($ConnectionTest) { 'connection-test' } else { 'live' }
Write-HudLog -Level INFO -Message ("Process started; mode={0}; demo={1}; selfTest={2}; rpcSelfTest={3}; connectionTest={4}; smokeTest={5}" -f $startupMode, $Demo.IsPresent, $SelfTest.IsPresent, $RpcSelfTest.IsPresent, $ConnectionTest.IsPresent, $SmokeTest.IsPresent)
Register-ProcessDiagnostics

# WPF's font cache requires WinDir. Some restricted launchers preserve
# SystemRoot but omit WinDir, so normalize it before loading WPF assemblies.
if ([string]::IsNullOrWhiteSpace($env:WINDIR)) {
    $env:WINDIR = $env:SystemRoot
}

function Get-NestedValue {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Paths
    )

    foreach ($path in $Paths) {
        $current = $InputObject
        $found = $true
        foreach ($segment in $path.Split('.')) {
            if ($null -eq $current) {
                $found = $false
                break
            }

            $property = $current.PSObject.Properties[$segment]
            if ($null -eq $property) {
                $found = $false
                break
            }
            $current = $property.Value
        }

        if ($found -and $null -ne $current) {
            return $current
        }
    }

    return $null
}

function Convert-ToDateTime {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    $number = 0.0
    if ([double]::TryParse([string]$Value, [ref]$number)) {
        if ($number -gt 100000000000) {
            $number = $number / 1000
        }
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$number).LocalDateTime
    }

    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed.LocalDateTime
    }

    return $null
}

function Get-WindowSummary {
    param($Window)

    if ($null -eq $Window) {
        return [pscustomobject]@{ Remaining = $null; ResetAt = $null }
    }

    $used = Get-NestedValue -InputObject $Window -Paths @('used_percent', 'usedPercent', 'percent_used')
    $remaining = Get-NestedValue -InputObject $Window -Paths @('remaining_percent', 'remainingPercent', 'percent_remaining')
    if ($null -eq $remaining -and $null -ne $used) {
        $remaining = 100 - [double]$used
    }
    if ($null -ne $remaining) {
        $remaining = [Math]::Max(0, [Math]::Min(100, [Math]::Round([double]$remaining)))
    }

    $resetValue = Get-NestedValue -InputObject $Window -Paths @('reset_at', 'resetAt', 'resets_at', 'resetsAt')
    return [pscustomobject]@{
        Remaining = $remaining
        ResetAt = Convert-ToDateTime $resetValue
    }
}

function Get-WindowDurationMinutes {
    param($Window)

    if ($null -eq $Window) { return $null }
    return Get-NestedValue -InputObject $Window -Paths @(
        'window_duration_mins', 'windowDurationMins',
        'window_duration_minutes', 'windowDurationMinutes'
    )
}

function Convert-AppServerResponse {
    param(
        [Parameter(Mandatory = $true)]$Response
    )

    $primary = Get-NestedValue -InputObject $Response -Paths @(
        'rateLimits.primary', 'rate_limits.primary',
        'rateLimit.primary', 'primary'
    )
    $secondary = Get-NestedValue -InputObject $Response -Paths @(
        'rateLimits.secondary', 'rate_limits.secondary',
        'rateLimit.secondary', 'secondary'
    )
    $primaryDuration = Get-WindowDurationMinutes $primary
    $secondaryDuration = Get-WindowDurationMinutes $secondary
    $fiveHour = if ($primaryDuration -eq 300) {
        $primary
    } elseif ($secondaryDuration -eq 300) {
        $secondary
    } elseif ($null -eq $primaryDuration -and $null -eq $secondaryDuration) {
        $primary
    } else {
        $null
    }
    $weekly = if ($primaryDuration -eq 10080) {
        $primary
    } elseif ($secondaryDuration -eq 10080) {
        $secondary
    } elseif ($null -eq $primaryDuration -and $null -eq $secondaryDuration) {
        $secondary
    } else {
        $null
    }

    $resetCredits = Get-NestedValue -InputObject $Response -Paths @(
        'rateLimitResetCredits', 'rate_limit_reset_credits',
        'rateLimits.rateLimitResetCredits', 'resetCredits'
    )
    $credits = if ($null -eq $resetCredits) {
        @()
    } else {
        @(Get-NestedValue -InputObject $resetCredits -Paths @(
            'credits', 'items', 'expirations', 'expirationDetails', 'available'
        ))
    }
    $availableCredits = @($credits | Where-Object {
        if ($null -eq $_) { return $false }
        $status = [string](Get-NestedValue -InputObject $_ -Paths @('status', 'state'))
        [string]::IsNullOrWhiteSpace($status) -or $status -eq 'available'
    })

    $availableCount = if ($null -eq $resetCredits) {
        $null
    } else {
        Get-NestedValue -InputObject $resetCredits -Paths @('available_count', 'availableCount')
    }
    if ($null -eq $availableCount -and $availableCredits.Count -gt 0) {
        $availableCount = $availableCredits.Count
    }

    $expirations = @($availableCredits | ForEach-Object {
        $value = Get-NestedValue -InputObject $_ -Paths @('expires_at', 'expiresAt', 'expiresOn', 'expiration')
        if ($null -eq $value) { $value = $_ }
        Convert-ToDateTime $value
    } | Where-Object { $null -ne $_ } | Sort-Object)
    $directExpiry = if ($null -eq $resetCredits) {
        $null
    } else {
        Get-NestedValue -InputObject $resetCredits -Paths @('nextExpiresAt', 'next_expires_at', 'earliestExpiresAt')
    }
    if ($null -ne $directExpiry) {
        $parsedDirectExpiry = Convert-ToDateTime $directExpiry
        if ($null -ne $parsedDirectExpiry) {
            $expirations = @($expirations + $parsedDirectExpiry | Sort-Object)
        }
    }

    return [pscustomobject]@{
        Primary = Get-WindowSummary $fiveHour
        Secondary = Get-WindowSummary $weekly
        AvailableResetCredits = if ($null -eq $availableCount) { $null } else { [int]$availableCount }
        NextCreditExpiry = if ($expirations.Count -gt 0) { $expirations[0] } else { $null }
        UpdatedAt = Get-Date
        DataSource = 'codex app-server'
    }
}

function Test-UsageData {
    param(
        [Parameter(Mandatory = $true)]$Data
    )

    if ($null -eq $Data) { return $false }
    $primary = $Data.Primary
    $secondary = $Data.Secondary
    return (
        ($null -ne $primary -and ($null -ne $primary.Remaining -or $null -ne $primary.ResetAt)) -or
        ($null -ne $secondary -and ($null -ne $secondary.Remaining -or $null -ne $secondary.ResetAt)) -or
        $null -ne $Data.AvailableResetCredits -or
        $null -ne $Data.NextCreditExpiry
    )
}

function Get-DemoData {
    $response = [pscustomobject]@{
        rateLimits = [pscustomobject]@{
            primary = [pscustomobject]@{
                usedPercent = 28
                windowDurationMins = 300
                resetsAt = [DateTimeOffset]::Now.AddHours(2).ToUnixTimeSeconds()
            }
            secondary = [pscustomobject]@{
                usedPercent = 62
                windowDurationMins = 10080
                resetsAt = [DateTimeOffset]::Now.AddDays(3).ToUnixTimeSeconds()
            }
        }
        rateLimitResetCredits = [pscustomobject]@{
            availableCount = 3
            credits = @(
                [pscustomobject]@{ status = 'available'; expiresAt = [DateTimeOffset]::Now.AddDays(5).ToString('o') },
                [pscustomobject]@{ status = 'available'; expiresAt = [DateTimeOffset]::Now.AddDays(8).ToString('o') },
                [pscustomobject]@{ status = 'available'; expiresAt = [DateTimeOffset]::Now.AddDays(12).ToString('o') }
            )
        }
    }
    return Convert-AppServerResponse -Response $response
}

function Resolve-CodexCommand {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_USAGE_HUD_CODEX)) {
        if (-not (Test-Path -LiteralPath $env:CODEX_USAGE_HUD_CODEX -PathType Leaf)) {
            throw "CODEX_USAGE_HUD_CODEX 指向的文件不存在：$env:CODEX_USAGE_HUD_CODEX"
        }
        return (Resolve-Path -LiteralPath $env:CODEX_USAGE_HUD_CODEX).Path
    }

    $configuredPathFile = Join-Path $PSScriptRoot 'codex-path.txt'
    if (Test-Path -LiteralPath $configuredPathFile -PathType Leaf) {
        $configuredPath = ([IO.File]::ReadAllText($configuredPathFile)).Trim()
        if (-not [string]::IsNullOrWhiteSpace($configuredPath) -and
            (Test-Path -LiteralPath $configuredPath -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $configuredPath).Path
        }
    }

    $npmCommand = if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $null
    } else {
        Join-Path $env:APPDATA 'npm\codex.cmd'
    }
    if ($null -ne $npmCommand -and (Test-Path -LiteralPath $npmCommand -PathType Leaf)) {
        return $npmCommand
    }

    $command = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command -or [string]::IsNullOrWhiteSpace($command.Path)) {
        throw '未找到 Codex CLI。请安装官方 Codex CLI，并确保 codex 命令位于 PATH。'
    }
    return $command.Path
}

function Start-CodexAppServer {
    param(
        [Parameter(Mandatory = $true)][string]$CommandPath
    )

    Write-HudLog -Level INFO -Message ('Starting Codex app-server ({0})' -f [IO.Path]::GetFileName($CommandPath))
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $extension = [IO.Path]::GetExtension($CommandPath)
    if ($extension -eq '.cmd' -or $extension -eq '.bat') {
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = ('/d /s /c ""{0}" app-server"' -f $CommandPath)
    } else {
        $startInfo.FileName = $CommandPath
        $startInfo.Arguments = 'app-server'
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Codex app-server 进程没有启动。'
        }
        Write-HudLog -Level INFO -Message ('Codex app-server started; childPid={0}' -f $process.Id)
    } catch {
        Write-HudException -Context 'Start Codex app-server failed' -Exception $_.Exception
        $process.Dispose()
        throw "无法启动 Codex CLI：$($_.Exception.Message)。如果当前命令来自 Codex Desktop 安装目录，请另外安装官方 Codex CLI。"
    }
    return $process
}

function Send-AppServerMessage {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)]$Message
    )
    $json = $Message | ConvertTo-Json -Compress -Depth 10
    $Process.StandardInput.WriteLine($json)
    $Process.StandardInput.Flush()
}

function Read-AppServerResponse {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][int]$Id,
        [int]$TimeoutMs = $script:RpcTimeoutMs
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $readTask = $Process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) {
            throw "等待 Codex app-server 响应超时（请求 $Id）。"
        }
        $line = $readTask.Result
        if ($null -eq $line) {
            $exitDescription = if ($Process.HasExited) { [string]$Process.ExitCode } else { '未知' }
            throw "Codex app-server 已退出（退出码：$exitDescription）。"
        }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try { $message = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $message.PSObject.Properties['id'] -or [int]$message.id -ne $Id) { continue }
        if ($null -ne $message.PSObject.Properties['error'] -and $null -ne $message.error) {
            $errorText = Get-NestedValue -InputObject $message -Paths @('error.message')
            throw "Codex app-server 请求失败：$errorText"
        }
        if ($null -eq $message.PSObject.Properties['result']) {
            throw 'Codex app-server 返回了没有 result 的响应。'
        }
        return $message.result
    }
    throw "等待 Codex app-server 响应超时（请求 $Id）。"
}

function Get-LiveData {
    $commandPath = Resolve-CodexCommand
    Write-HudLog -Level INFO -Message ('Resolved Codex command ({0})' -f [IO.Path]::GetFileName($commandPath))
    $process = Start-CodexAppServer -CommandPath $commandPath
    try {
        Send-AppServerMessage -Process $process -Message @{
            id = 1
            method = 'initialize'
            params = @{ clientInfo = @{ name = 'codex-usage-hud'; version = '2.0.0' } }
        }
        [void](Read-AppServerResponse -Process $process -Id 1)
        Send-AppServerMessage -Process $process -Message @{ method = 'initialized'; params = @{} }
        Send-AppServerMessage -Process $process -Message @{ id = 2; method = 'account/rateLimits/read'; params = @{} }
        $response = Read-AppServerResponse -Process $process -Id 2
        $data = Convert-AppServerResponse -Response $response
        if (-not (Test-UsageData -Data $data)) {
            throw 'Codex app-server 返回了空的用量数据。'
        }
        Write-HudLog -Level INFO -Message 'Codex app-server returned account/rateLimits/read.'
        return $data
    } finally {
        try { $process.StandardInput.Close() } catch { Write-HudException -Context 'Close Codex app-server stdin failed' -Exception $_.Exception }
        if (-not $process.HasExited) {
            try {
                $process.Kill()
                Write-HudLog -Level INFO -Message ('Stopped Codex app-server; childPid={0}' -f $process.Id)
            } catch { Write-HudException -Context 'Stop Codex app-server failed' -Exception $_.Exception }
        }
        $process.Dispose()
    }
}

function Get-CountdownText {
    param([Nullable[DateTime]]$Target)

    if ($null -eq $Target) { return '时间未知' }
    $span = $Target - (Get-Date)
    if ($span.TotalSeconds -le 0) { return '即将刷新' }
    if ($span.TotalDays -ge 1) { return ('{0}天 {1}小时后' -f [Math]::Floor($span.TotalDays), $span.Hours) }
    if ($span.TotalHours -ge 1) { return ('{0}小时 {1}分后' -f [Math]::Floor($span.TotalHours), $span.Minutes) }
    return ('{0}分钟后' -f [Math]::Max(1, [Math]::Ceiling($span.TotalMinutes)))
}

if ($SelfTest) {
    $result = Get-DemoData
    if ($result.Primary.Remaining -ne 72 -or
        $result.Secondary.Remaining -ne 38 -or
        $result.AvailableResetCredits -ne 3 -or
        $null -eq $result.NextCreditExpiry) {
        throw 'Self-test failed.'
    }
    $countOnly = Convert-AppServerResponse -Response ([pscustomobject]@{
        rateLimits = [pscustomobject]@{}
        rateLimitResetCredits = [pscustomobject]@{ availableCount = 2 }
    })
    $missing = Convert-AppServerResponse -Response ([pscustomobject]@{ rateLimits = [pscustomobject]@{} })
    $weeklyOnly = Convert-AppServerResponse -Response ([pscustomobject]@{
        rateLimits = [pscustomobject]@{
            primary = [pscustomobject]@{
                usedPercent = 6
                windowDurationMins = 10080
                resetsAt = [DateTimeOffset]::Now.AddDays(7).ToUnixTimeSeconds()
            }
        }
    })
    $futureCountdown = Get-CountdownText ([DateTime]::Now.AddDays(2))
    if ($countOnly.AvailableResetCredits -ne 2 -or
        $null -ne $countOnly.NextCreditExpiry -or
        $null -ne $missing.AvailableResetCredits -or
        $null -ne $weeklyOnly.Primary.Remaining -or
        $weeklyOnly.Secondary.Remaining -ne 94 -or
        $futureCountdown -eq '即将刷新') {
        throw 'Self-test failed: missing-field semantics.'
    }
    $empty = Convert-AppServerResponse -Response ([pscustomobject]@{ rateLimits = [pscustomobject]@{} })
    if (Test-UsageData -Data $empty) {
        throw 'Self-test failed: empty usage payload was accepted.'
    }
    Write-Output 'PASS: response parsing and reset-credit expiry selection'
    exit 0
}

if ($RpcSelfTest) {
    $result = Get-LiveData
    if ($result.Primary.Remaining -ne 72 -or
        $result.Secondary.Remaining -ne 38 -or
        $result.AvailableResetCredits -ne 3 -or
        $null -eq $result.NextCreditExpiry) {
        throw 'RPC self-test failed.'
    }
    Write-Output 'PASS: app-server process handshake and rate-limit request'
    exit 0
}

if ($ConnectionTest) {
    [void](Get-LiveData)
    Write-Output 'PASS: Codex app-server account connection'
    exit 0
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HudNativeMethods {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="142" Height="44" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        ResizeMode="NoResize" UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI"
        TextOptions.TextFormattingMode="Ideal" TextOptions.TextHintingMode="Fixed">
    <Grid Background="#01FFFFFF">
        <Grid x:Name="CompactView" Width="140" Height="42" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Border CornerRadius="21" Margin="0" BorderBrush="#35FFFFFF" BorderThickness="1" IsHitTestVisible="False">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#F31C252E" Offset="0"/>
                        <GradientStop Color="#F012171F" Offset="0.54"/>
                        <GradientStop Color="#F51A222B" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
            </Border>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="1*"/>
                    <ColumnDefinition Width="1*"/>
                </Grid.ColumnDefinitions>

                <Grid Grid.Column="0" Margin="11,4,7,4">
                    <Viewbox Width="53" Height="25" Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Center" VerticalAlignment="Center">
                        <TextBlock x:Name="CompactPrimaryValue" Text="--%" Foreground="#55D9FF"
                                   FontFamily="Segoe UI Variable Display, Segoe UI, Microsoft YaHei UI" FontSize="21" FontWeight="SemiBold"
                                   TextAlignment="Center"/>
                    </Viewbox>
                    <Border x:Name="CompactPrimaryFill" Height="2" Width="0" VerticalAlignment="Bottom" HorizontalAlignment="Left"
                            Background="#D955D9FF" CornerRadius="1" IsHitTestVisible="False"/>
                </Grid>

                <Border Grid.ColumnSpan="2" Width="1" Height="22" Background="#36FFFFFF" VerticalAlignment="Center" IsHitTestVisible="False"/>

                <Grid Grid.Column="1" Margin="7,4,11,4">
                    <Viewbox Width="53" Height="25" Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Center" VerticalAlignment="Center">
                        <TextBlock x:Name="CompactSecondaryValue" Text="--%" Foreground="#9CB5FF"
                                   FontFamily="Segoe UI Variable Display, Segoe UI, Microsoft YaHei UI" FontSize="21" FontWeight="SemiBold"
                                   TextAlignment="Center"/>
                    </Viewbox>
                    <Border x:Name="CompactSecondaryFill" Height="2" Width="0" VerticalAlignment="Bottom" HorizontalAlignment="Left"
                            Background="#D99CB5FF" CornerRadius="1" IsHitTestVisible="False"/>
                </Grid>
            </Grid>
            <Border Height="1" Margin="12,1,12,0" VerticalAlignment="Top" Background="#3DFFFFFF" Opacity="0.55" IsHitTestVisible="False"/>
        </Grid>

        <Grid x:Name="DetailView" Visibility="Collapsed" Margin="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="82"/>
                <ColumnDefinition Width="1"/>
                <ColumnDefinition Width="116"/>
                <ColumnDefinition Width="1"/>
                <ColumnDefinition Width="116"/>
                <ColumnDefinition Width="1"/>
                <ColumnDefinition Width="70"/>
                <ColumnDefinition Width="1"/>
                <ColumnDefinition Width="88"/>
                <ColumnDefinition Width="1"/>
                <ColumnDefinition Width="21"/>
            </Grid.ColumnDefinitions>

            <Border Grid.ColumnSpan="11" CornerRadius="21" BorderBrush="#3AFFFFFF" BorderThickness="1" Padding="0" IsHitTestVisible="False">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#F51E2731" Offset="0"/>
                        <GradientStop Color="#F012171F" Offset="0.50"/>
                        <GradientStop Color="#F71A222B" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
            </Border>

            <Border Grid.Column="1" Height="54" Background="#2DFFFFFF" VerticalAlignment="Center" IsHitTestVisible="False"/>
            <Border Grid.Column="3" Height="54" Background="#2DFFFFFF" VerticalAlignment="Center" IsHitTestVisible="False"/>
            <Border Grid.Column="5" Height="54" Background="#2DFFFFFF" VerticalAlignment="Center" IsHitTestVisible="False"/>
            <Border Grid.Column="7" Height="54" Background="#2DFFFFFF" VerticalAlignment="Center" IsHitTestVisible="False"/>
            <Border Grid.Column="9" Height="54" Background="#2DFFFFFF" VerticalAlignment="Center" IsHitTestVisible="False"/>

            <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="11,0,5,0">
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="StatusDot" Width="6" Height="6" Fill="#34C759" Margin="0,3,6,0"/>
                    <TextBlock Text="Codex" Foreground="#F1F5F8" FontFamily="Segoe UI Variable Display, Segoe UI, Microsoft YaHei UI" FontSize="13" FontWeight="SemiBold"/>
                </StackPanel>
                <TextBlock x:Name="StatusText" Text="APP-SERVER" Foreground="#9CAAB6" FontSize="8.5" FontWeight="SemiBold" Margin="12,3,0,0"/>
            </StackPanel>

            <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="11,0,6,0">
                <TextBlock Text="5 小时" Foreground="#9CAAB6" FontSize="9.5" FontWeight="SemiBold"/>
                <TextBlock x:Name="PrimaryValue" Text="--%" Foreground="#55D9FF" FontFamily="Segoe UI Variable Display, Segoe UI, Microsoft YaHei UI" FontSize="22" FontWeight="SemiBold"/>
                <ProgressBar x:Name="PrimaryBar" Height="4" Maximum="100" Value="0" Background="#3BFFFFFF" Foreground="#55D9FF" BorderThickness="0" Margin="0,2,0,2"/>
                <TextBlock x:Name="PrimaryReset" Text="等待刷新" Foreground="#9CAAB6" FontSize="8.5" FontWeight="Medium" TextTrimming="CharacterEllipsis"/>
            </StackPanel>

            <StackPanel Grid.Column="4" VerticalAlignment="Center" Margin="11,0,6,0">
                <TextBlock Text="每周额度" Foreground="#9CAAB6" FontSize="9.5" FontWeight="SemiBold"/>
                <TextBlock x:Name="SecondaryValue" Text="--%" Foreground="#9CB5FF" FontFamily="Segoe UI Variable Display, Segoe UI, Microsoft YaHei UI" FontSize="22" FontWeight="SemiBold"/>
                <ProgressBar x:Name="SecondaryBar" Height="4" Maximum="100" Value="0" Background="#3BFFFFFF" Foreground="#9CB5FF" BorderThickness="0" Margin="0,2,0,2"/>
                <TextBlock x:Name="SecondaryReset" Text="等待刷新" Foreground="#9CAAB6" FontSize="8.5" FontWeight="Medium" TextTrimming="CharacterEllipsis"/>
            </StackPanel>

            <StackPanel Grid.Column="6" VerticalAlignment="Center" Margin="8,0,4,0">
                <TextBlock Text="重置卡" Foreground="#9CAAB6" FontSize="9.5" FontWeight="SemiBold"/>
                <StackPanel Orientation="Horizontal" Margin="0,1,0,0">
                    <TextBlock x:Name="CreditValue" Text="--" Foreground="#F1F5F8" FontFamily="Segoe UI Variable Display, Segoe UI, Microsoft YaHei UI" FontSize="22" FontWeight="SemiBold"/>
                    <TextBlock Text=" 张" Foreground="#9CAAB6" FontSize="8.5" FontWeight="Medium" VerticalAlignment="Bottom" Margin="2,0,0,3"/>
                </StackPanel>
            </StackPanel>

            <StackPanel Grid.Column="8" VerticalAlignment="Center" Margin="8,0,4,0">
                <TextBlock Text="最近到期" Foreground="#9CAAB6" FontSize="9.5" FontWeight="SemiBold"/>
                <TextBlock x:Name="ExpiryValue" Text="--" Foreground="#F1F5F8" FontFamily="Segoe UI Variable Display, Segoe UI, Microsoft YaHei UI" FontSize="12.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="ExpiryCountdown" Text="没有可用卡" Foreground="#9CAAB6" FontSize="8.5" FontWeight="Medium" TextTrimming="CharacterEllipsis"/>
            </StackPanel>

            <StackPanel Grid.Column="10" VerticalAlignment="Center" HorizontalAlignment="Center">
                <TextBlock x:Name="RefreshGlyph" Text="↻" Foreground="#8EA5B6" FontSize="16" FontWeight="SemiBold" ToolTip="双击悬浮条立即刷新"/>
                <TextBlock x:Name="UpdatedText" Text="--:--" Foreground="#8E8E93"
                           FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI"
                           FontSize="8.5" FontWeight="Medium" TextAlignment="Center"
                           HorizontalAlignment="Center" Margin="0,-1,0,0"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $compactView = $window.FindName('CompactView')
    $detailView = $window.FindName('DetailView')
    $compactPrimaryValue = $window.FindName('CompactPrimaryValue')
    $compactSecondaryValue = $window.FindName('CompactSecondaryValue')
    $compactPrimaryFill = $window.FindName('CompactPrimaryFill')
    $compactSecondaryFill = $window.FindName('CompactSecondaryFill')
    $statusDot = $window.FindName('StatusDot')
    $statusText = $window.FindName('StatusText')
    $primaryValue = $window.FindName('PrimaryValue')
    $primaryBar = $window.FindName('PrimaryBar')
    $primaryReset = $window.FindName('PrimaryReset')
    $secondaryValue = $window.FindName('SecondaryValue')
    $secondaryBar = $window.FindName('SecondaryBar')
    $secondaryReset = $window.FindName('SecondaryReset')
    $creditValue = $window.FindName('CreditValue')
    $expiryValue = $window.FindName('ExpiryValue')
    $expiryCountdown = $window.FindName('ExpiryCountdown')
    $refreshGlyph = $window.FindName('RefreshGlyph')
    $updatedText = $window.FindName('UpdatedText')

    try {
        $script:DispatcherUnhandledExceptionHandler = [Windows.Threading.DispatcherUnhandledExceptionEventHandler]{
            param($sender, $eventArgs)
            try {
                Write-HudException -Context 'WPF Dispatcher.UnhandledException' -Exception $eventArgs.Exception
                # Keep the HUD alive after an isolated dispatcher callback failure.
                $eventArgs.Handled = $true
                if ($null -ne $statusText -and $null -ne $window -and $window.IsVisible) {
                    $statusDot.Fill = Get-Brush '#FF3B30'
                    $statusText.Text = '刷新失败'
                    $updatedText.Text = '错误'
                    $window.ToolTip = $eventArgs.Exception.Message
                }
            } catch {
                Write-HudException -Context 'WPF Dispatcher.UnhandledException handler failed' -Exception $_.Exception
            }
        }
        $window.Dispatcher.add_UnhandledException($script:DispatcherUnhandledExceptionHandler)
        Write-HudLog -Level INFO -Message 'Registered WPF dispatcher exception handler.'
    } catch {
        Write-HudException -Context 'Register WPF dispatcher exception handler failed' -Exception $_.Exception
    }

    function Get-Brush([string]$Hex) {
        return [Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
    }

    function New-HudTrayIcon {
        $bitmap = [Drawing.Bitmap]::new(32, 32, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $backgroundPath = [Drawing.Drawing2D.GraphicsPath]::new()
        $topMeterPath = [Drawing.Drawing2D.GraphicsPath]::new()
        $bottomMeterPath = [Drawing.Drawing2D.GraphicsPath]::new()
        $backgroundBrush = $null
        $meterBrush = $null
        $highlightPen = $null
        $iconHandle = [IntPtr]::Zero

        try {
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.Clear([Drawing.Color]::Transparent)

            $backgroundPath.AddArc(3, 3, 9, 9, 180, 90)
            $backgroundPath.AddArc(20, 3, 9, 9, 270, 90)
            $backgroundPath.AddArc(20, 20, 9, 9, 0, 90)
            $backgroundPath.AddArc(3, 20, 9, 9, 90, 90)
            $backgroundPath.CloseFigure()

            $backgroundBrush = [Drawing.Drawing2D.LinearGradientBrush]::new(
                [Drawing.RectangleF]::new(3, 3, 26, 26),
                [Drawing.Color]::FromArgb(255, 90, 200, 250),
                [Drawing.Color]::FromArgb(255, 0, 122, 255),
                90.0
            )
            $graphics.FillPath($backgroundBrush, $backgroundPath)
            $highlightPen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(135, 255, 255, 255), 1.0)
            $graphics.DrawPath($highlightPen, $backgroundPath)

            $topMeterPath.AddArc(8, 10, 4, 4, 90, 180)
            $topMeterPath.AddLine(10, 10, 22, 10)
            $topMeterPath.AddArc(20, 10, 4, 4, 270, 180)
            $topMeterPath.AddLine(22, 14, 10, 14)
            $topMeterPath.CloseFigure()

            $bottomMeterPath.AddArc(8, 18, 4, 4, 90, 180)
            $bottomMeterPath.AddLine(10, 18, 18, 18)
            $bottomMeterPath.AddArc(16, 18, 4, 4, 270, 180)
            $bottomMeterPath.AddLine(18, 22, 10, 22)
            $bottomMeterPath.CloseFigure()

            $meterBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(245, 255, 255, 255))
            $graphics.FillPath($meterBrush, $topMeterPath)
            $graphics.FillPath($meterBrush, $bottomMeterPath)

            $iconHandle = $bitmap.GetHicon()
            return [Drawing.Icon]::FromHandle($iconHandle).Clone()
        } finally {
            if ($iconHandle -ne [IntPtr]::Zero) { [void][HudNativeMethods]::DestroyIcon($iconHandle) }
            if ($null -ne $highlightPen) { $highlightPen.Dispose() }
            if ($null -ne $meterBrush) { $meterBrush.Dispose() }
            if ($null -ne $backgroundBrush) { $backgroundBrush.Dispose() }
            $bottomMeterPath.Dispose()
            $topMeterPath.Dispose()
            $backgroundPath.Dispose()
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }

    function Set-Meter {
        param($TextElement, $BarElement, $ResetElement, $Summary)
        if ($null -eq $Summary.Remaining) {
            $TextElement.Text = '--%'
            $TextElement.Foreground = Get-Brush '#86868B'
            $BarElement.Value = 0
            $ResetElement.Text = '暂无数据'
            return
        }

        $remaining = [int]$Summary.Remaining
        $color = if ($remaining -le 10) {
            '#FF5B65'
        } elseif ($remaining -le 25) {
            '#F2B84B'
        } elseif ($BarElement.Name -eq 'SecondaryBar') {
            '#9CB5FF'
        } else {
            '#55D9FF'
        }
        $TextElement.Text = "$remaining%"
        $TextElement.Foreground = Get-Brush $color
        $BarElement.Value = $remaining
        $BarElement.Foreground = Get-Brush $color
        $ResetElement.Text = "重置：$(Get-CountdownText $Summary.ResetAt)"
    }

    function Set-CompactFill {
        param($FillElement, $Summary, $ValueElement)
        if ($null -eq $Summary.Remaining) {
            $FillElement.Height = 0
            if ($null -ne $FillElement.PSObject.Properties['Width']) { $FillElement.Width = 0 }
            $fillBrush = Get-Brush '#2B7C98AC'
            if ($null -ne $FillElement.PSObject.Properties['Fill']) {
                $FillElement.Fill = $fillBrush
            } else {
                $FillElement.Background = $fillBrush
            }
            return
        }

        $availableWidth = 52.0
        if ($null -ne $FillElement.Parent -and $FillElement.Parent.ActualWidth -gt 0) {
            $availableWidth = [double]$FillElement.Parent.ActualWidth
        }
        $FillElement.Height = 2
        if ($null -ne $FillElement.PSObject.Properties['Width']) {
            $FillElement.Width = [Math]::Max(0, [Math]::Min(
                $availableWidth,
                ([double]$Summary.Remaining * $availableWidth / 100.0)
            ))
        }
        $remaining = [int]$Summary.Remaining
        $fillHex = if ($remaining -le 10) {
            '#D9FF5B65'
        } elseif ($remaining -le 25) {
            '#D9F2B84B'
        } elseif ($FillElement.Name -eq 'CompactSecondaryFill') {
            '#D99CB5FF'
        } else {
            '#D955D9FF'
        }
        $fillBrush = Get-Brush $fillHex
        if ($null -ne $FillElement.PSObject.Properties['Fill']) {
            $FillElement.Fill = $fillBrush
        } else {
            $FillElement.Background = $fillBrush
        }
    }

    function Update-Hud {
        param($Data)
        Set-Meter $primaryValue $primaryBar $primaryReset $Data.Primary
        Set-Meter $secondaryValue $secondaryBar $secondaryReset $Data.Secondary
        Set-CompactFill $compactPrimaryFill $Data.Primary $primaryValue
        Set-CompactFill $compactSecondaryFill $Data.Secondary $secondaryValue
        $compactPrimaryValue.Text = $primaryValue.Text
        $compactPrimaryValue.Foreground = $primaryValue.Foreground
        $compactSecondaryValue.Text = $secondaryValue.Text
        $compactSecondaryValue.Foreground = $secondaryValue.Foreground
        $creditValue.Text = if ($null -eq $Data.AvailableResetCredits) { '--' } else { [string]$Data.AvailableResetCredits }
        if ($null -eq $Data.AvailableResetCredits) {
            $expiryValue.Text = '不可用'
            $expiryCountdown.Text = '当前 Codex 未返回重置卡数据'
        } elseif ($Data.AvailableResetCredits -gt 0 -and $null -ne $Data.NextCreditExpiry) {
            $expiryValue.Text = $Data.NextCreditExpiry.ToString('MM-dd  HH:mm')
            $expiryCountdown.Text = Get-CountdownText $Data.NextCreditExpiry
        } elseif ($Data.AvailableResetCredits -gt 0) {
            $expiryValue.Text = '未提供'
            $expiryCountdown.Text = '当前 Codex 未返回到期时间'
        } else {
            $expiryValue.Text = '—'
            $expiryCountdown.Text = '没有可用卡'
        }
        $statusDot.Fill = Get-Brush '#34C759'
        $statusText.Text = if ($Demo) { '演示数据' } else { 'APP-SERVER' }
        $updatedText.Text = $Data.UpdatedAt.ToString('HH:mm')
        $window.ToolTip = $null
    }

    function Set-HudError {
        param([string]$Message)
        $statusDot.Fill = Get-Brush '#FF3B30'
        $statusText.Text = '刷新失败'
        $updatedText.Text = '错误'
        $window.ToolTip = $Message
    }

    function Refresh-Hud {
        if ($script:IsRefreshing) { return }
        $script:IsRefreshing = $true
        $refreshGlyph.Foreground = Get-Brush '#007AFF'
        $refreshMode = if ($Demo) { 'demo' } else { 'live' }
        Write-HudLog -Level INFO -Message ('Refresh started; mode={0}' -f $refreshMode)
        try {
            $data = if ($Demo) { Get-DemoData } else { Get-LiveData }
            Update-Hud $data
            Write-HudLog -Level INFO -Message 'Refresh succeeded.'
        } catch {
            Write-HudException -Context 'Refresh failed' -Exception $_.Exception
            try {
                Set-HudError $_.Exception.Message
            } catch {
                Write-HudException -Context 'Update HUD error state failed' -Exception $_.Exception
            }
        } finally {
            $refreshGlyph.Foreground = Get-Brush '#8E8E93'
            $script:IsRefreshing = $false
        }
    }

    function Set-ClickThrough {
        param([bool]$Enabled)
        $handle = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
        $GWL_EXSTYLE = -20
        $WS_EX_TRANSPARENT = 0x20
        $style = [HudNativeMethods]::GetWindowLong($handle, $GWL_EXSTYLE)
        if ($Enabled) { $style = $style -bor $WS_EX_TRANSPARENT }
        else { $style = $style -band (-bnot $WS_EX_TRANSPARENT) }
        [void][HudNativeMethods]::SetWindowLong($handle, $GWL_EXSTYLE, $style)
    }

    $script:IsHudExpanded = $false
    $script:IsHudDragging = $false
    $script:CompactLeft = 0.0
    $script:CompactTop = 0.0
    $script:CompactWidth = 142.0
    $script:CompactHeight = 44.0
    $script:DetailWidth = 500.0
    $script:DetailHeight = 90.0

    function Get-CompactWorkingArea {
        $center = [System.Drawing.Point]::new(
            [int]($script:CompactLeft + ($script:CompactWidth / 2)),
            [int]($script:CompactTop + ($script:CompactHeight / 2))
        )
        return [System.Windows.Forms.Screen]::FromPoint($center).WorkingArea
    }

    function Clamp-CompactAnchor {
        $area = Get-CompactWorkingArea
        $script:CompactLeft = [Math]::Max($area.Left, [Math]::Min(
            $script:CompactLeft,
            $area.Right - $script:CompactWidth
        ))
        $script:CompactTop = [Math]::Max($area.Top, [Math]::Min(
            $script:CompactTop,
            $area.Bottom - $script:CompactHeight
        ))
    }

    function Apply-HudLayout {
        $area = Get-CompactWorkingArea
        if ($script:IsHudExpanded) {
            $window.Width = $script:DetailWidth
            $window.Height = $script:DetailHeight
            $desiredLeft = $script:CompactLeft + (($script:CompactWidth - $script:DetailWidth) / 2)
            $window.Left = [Math]::Max($area.Left, [Math]::Min(
                $desiredLeft,
                $area.Right - $script:DetailWidth
            ))
            $window.Top = [Math]::Max($area.Top, [Math]::Min(
                $script:CompactTop,
                $area.Bottom - $script:DetailHeight
            ))
            $compactView.Visibility = [Windows.Visibility]::Collapsed
            $detailView.Visibility = [Windows.Visibility]::Visible
        } else {
            $window.Width = $script:CompactWidth
            $window.Height = $script:CompactHeight
            $window.Left = $script:CompactLeft
            $window.Top = $script:CompactTop
            $detailView.Visibility = [Windows.Visibility]::Collapsed
            $compactView.Visibility = [Windows.Visibility]::Visible
        }
    }

    function Set-HudExpanded {
        param([bool]$Expanded)

        if ($script:IsHudExpanded -eq $Expanded) { return }
        if ($Expanded) {
            $script:CompactLeft = $window.Left
            $script:CompactTop = $window.Top
        }
        $script:IsHudExpanded = $Expanded
        Clamp-CompactAnchor
        Apply-HudLayout
    }

    # The window changes size when it expands. Keep the whole window as one
    # hit-test surface and debounce the leave event so resizing cannot create
    # an expand/collapse loop under the pointer.
    $hoverCollapseTimer = New-Object Windows.Threading.DispatcherTimer
    $hoverCollapseTimer.Interval = [TimeSpan]::FromMilliseconds(220)
    $hoverCollapseTimer.Add_Tick({
        try {
            $hoverCollapseTimer.Stop()
            if (-not $window.IsMouseOver -and -not $script:IsHudDragging) {
                Set-HudExpanded $false
            }
        } catch {
            Write-HudException -Context 'Hover collapse callback failed' -Exception $_.Exception
            try { Set-HudError $_.Exception.Message } catch { Write-HudException -Context 'Set hover error state failed' -Exception $_.Exception }
        }
    })

    $window.Add_SourceInitialized({
        try {
            $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $window.Left = $area.Left + (($area.Width - $window.Width) / 2)
            $window.Top = $area.Top + 6
            $script:CompactLeft = $window.Left
            $script:CompactTop = $window.Top
            Clamp-CompactAnchor
            Apply-HudLayout
            Write-HudLog -Level INFO -Message ('Window initialized at left={0:N0}, top={1:N0}' -f $script:CompactLeft, $script:CompactTop)
        } catch {
            Write-HudException -Context 'Window SourceInitialized callback failed' -Exception $_.Exception
            try { Set-HudError $_.Exception.Message } catch { Write-HudException -Context 'Set initialization error state failed' -Exception $_.Exception }
        }
    })
    $window.Add_MouseEnter({
        try {
            $hoverCollapseTimer.Stop()
            Set-HudExpanded $true
        } catch {
            Write-HudException -Context 'MouseEnter callback failed' -Exception $_.Exception
            try { Set-HudError $_.Exception.Message } catch { Write-HudException -Context 'Set mouse-enter error state failed' -Exception $_.Exception }
        }
    })
    $window.Add_MouseLeave({
        try {
            if (-not $script:IsHudDragging) {
                $hoverCollapseTimer.Stop()
                $hoverCollapseTimer.Start()
            }
        } catch {
            Write-HudException -Context 'MouseLeave callback failed' -Exception $_.Exception
            try { Set-HudError $_.Exception.Message } catch { Write-HudException -Context 'Set mouse-leave error state failed' -Exception $_.Exception }
        }
    })
    $window.Add_MouseLeftButtonDown({
        try {
            if ($_.ClickCount -eq 2) { Refresh-Hud }
            else {
                $script:IsHudDragging = $true
                try { $window.DragMove() } finally { $script:IsHudDragging = $false }
                $script:CompactLeft = $window.Left + (($window.Width - $script:CompactWidth) / 2)
                $script:CompactTop = $window.Top
                Clamp-CompactAnchor
                Apply-HudLayout
                if (-not $window.IsMouseOver) { Set-HudExpanded $false }
            }
        } catch {
            Write-HudException -Context 'MouseLeftButtonDown callback failed' -Exception $_.Exception
            try { Set-HudError $_.Exception.Message } catch { Write-HudException -Context 'Set drag error state failed' -Exception $_.Exception }
        }
    })

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $trayIcon = New-HudTrayIcon
    $tray.Icon = $trayIcon
    $tray.Text = 'Codex 用量悬浮条'
    $tray.Visible = $true
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $refreshItem = $menu.Items.Add('立即刷新')
    $clickThroughItem = $menu.Items.Add('鼠标穿透')
    $clickThroughItem.CheckOnClick = $true
    $visibleItem = $menu.Items.Add('隐藏悬浮条')
    [void]$menu.Items.Add('-')
    $exitItem = $menu.Items.Add('退出')
    $tray.ContextMenuStrip = $menu

    $refreshItem.Add_Click({
        try { Refresh-Hud } catch { Write-HudException -Context 'Tray refresh callback failed' -Exception $_.Exception }
    })
    $clickThroughItem.Add_CheckedChanged({
        try {
            Set-ClickThrough $clickThroughItem.Checked
            Write-HudLog -Level INFO -Message ('Mouse-through changed; enabled={0}' -f $clickThroughItem.Checked)
        } catch {
            Write-HudException -Context 'Tray mouse-through callback failed' -Exception $_.Exception
        }
    })
    $visibleItem.Add_Click({
        try {
            if ($window.IsVisible) {
                $window.Hide()
                $visibleItem.Text = '显示悬浮条'
                Write-HudLog -Level INFO -Message 'Window hidden from tray menu.'
            } else {
                $window.Show()
                Clamp-CompactAnchor
                Apply-HudLayout
                $visibleItem.Text = '隐藏悬浮条'
                Write-HudLog -Level INFO -Message 'Window shown from tray menu.'
            }
        } catch {
            Write-HudException -Context 'Tray visibility callback failed' -Exception $_.Exception
        }
    })
    $tray.Add_DoubleClick({
        try {
            if (-not $window.IsVisible) { $window.Show(); $visibleItem.Text = '隐藏悬浮条' }
            Clamp-CompactAnchor
            Apply-HudLayout
            $window.Activate()
            Write-HudLog -Level INFO -Message 'Window restored from tray double-click.'
        } catch {
            Write-HudException -Context 'Tray double-click callback failed' -Exception $_.Exception
        }
    })
    $exitItem.Add_Click({
        try {
            $script:CloseReason = 'tray-exit'
            Write-HudLog -Level INFO -Message 'Exit requested from tray menu.'
            $window.Close()
        } catch {
            Write-HudException -Context 'Tray exit callback failed' -Exception $_.Exception
        }
    })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds($script:RefreshSeconds)
    $timer.Add_Tick({ Refresh-Hud })
    $timer.Start()
    $window.Add_ContentRendered({
        Write-HudLog -Level INFO -Message 'Window content rendered.'
        Refresh-Hud
        if ($SmokeTest) {
            $compactLeftBeforeExpand = $window.Left
            $compactTopBeforeExpand = $window.Top
            Set-HudExpanded $true
            Set-HudExpanded $false
            if ([Math]::Abs($window.Left - $compactLeftBeforeExpand) -gt 0.5 -or
                [Math]::Abs($window.Top - $compactTopBeforeExpand) -gt 0.5) {
                throw 'HUD compact anchor changed after expand/collapse.'
            }
            $script:CloseReason = 'smoke-test'
            Write-HudLog -Level INFO -Message 'Smoke test completed; closing test window.'
            $window.Close()
        }
    })
    $window.Add_Closed({
        Write-HudLog -Level INFO -Message ('Window closed; reason={0}' -f $script:CloseReason)
        try {
            $timer.Stop()
            $hoverCollapseTimer.Stop()
            $tray.Visible = $false
            $tray.Dispose()
            $trayIcon.Dispose()
        } catch {
            Write-HudException -Context 'Window Closed cleanup failed' -Exception $_.Exception
        }
    })

    [void]$window.ShowDialog()
    Write-HudLog -Level INFO -Message ('Window.ShowDialog returned; reason={0}' -f $script:CloseReason)
    if ($SmokeTest) { Write-Output 'PASS: WPF window loaded and rendered' }
} catch {
    Write-HudException -Context 'Fatal startup/UI exception' -Exception $_.Exception
    if ($SmokeTest) {
        Write-Error $_.Exception.ToString()
        exit 1
    }
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [void][System.Windows.MessageBox]::Show(
        $_.Exception.Message,
        'Codex Usage HUD 启动失败',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
    exit 1
}
