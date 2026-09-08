$ErrorActionPreference = 'Stop'

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $message = $line | ConvertFrom-Json

    if ($message.method -eq 'initialize') {
        [Console]::Out.WriteLine((@{
            id = $message.id
            result = @{ userAgent = 'fake-codex-app-server/1.0' }
        } | ConvertTo-Json -Compress -Depth 8))
        continue
    }

    if ($message.method -eq 'account/rateLimits/read') {
        [Console]::Out.WriteLine((@{
            id = $message.id
            result = @{
                rateLimits = @{
                    primary = @{
                        usedPercent = 28
                        windowDurationMins = 300
                        resetsAt = [DateTimeOffset]::Now.AddHours(2).ToUnixTimeSeconds()
                    }
                    secondary = @{
                        usedPercent = 62
                        windowDurationMins = 10080
                        resetsAt = [DateTimeOffset]::Now.AddDays(3).ToUnixTimeSeconds()
                    }
                }
                rateLimitResetCredits = @{
                    availableCount = 3
                    credits = @(
                        @{ status = 'available'; expiresAt = [DateTimeOffset]::Now.AddDays(5).ToString('o') },
                        @{ status = 'available'; expiresAt = [DateTimeOffset]::Now.AddDays(8).ToString('o') },
                        @{ status = 'available'; expiresAt = [DateTimeOffset]::Now.AddDays(12).ToString('o') }
                    )
                }
            }
        } | ConvertTo-Json -Compress -Depth 12))
    }
}
