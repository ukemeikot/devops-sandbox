#requires -Version 5.1
<#
.SYNOPSIS
    Auto-destroy expired environments (Windows-native parallel of cleanup_daemon.sh).
    Same contract: scan envs/*.json every CLEANUP_INTERVAL seconds, call
    destroy on anything past TTL, append every action to logs/cleanup.log.
#>

$ErrorActionPreference = 'Continue'   # Daemon must never die from one bad state file.

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $Root

$envFile = Join-Path $Root '.env'
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { return }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim().Trim('"').Trim("'")
        [Environment]::SetEnvironmentVariable($key, $val, 'Process')
    }
}

$intervalRaw = $env:CLEANUP_INTERVAL
$Interval = if ($intervalRaw) { [int]$intervalRaw } else { 60 }
$LogFile  = Join-Path $Root 'logs/cleanup.log'

New-Item -ItemType Directory -Force -Path (Join-Path $Root 'logs') | Out-Null

function Write-Daemon([string] $Message) {
    $line = ('{0} {1}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')), $Message)
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

# Pick the right destroy script for the daemon's host. A PowerShell daemon
# can call into either a .ps1 or a .sh — if bash is on PATH (Git Bash,
# WSL2), prefer it for parity with the Linux daemon.
$destroyShPath  = Join-Path $Root 'platform/destroy_env.sh'
$destroyPs1Path = Join-Path $Root 'platform/destroy_env.ps1'
$bashCmd = Get-Command 'bash' -ErrorAction SilentlyContinue

function Invoke-Destroy([string] $EnvId) {
    if ($bashCmd -and (Test-Path $destroyShPath)) {
        & $bashCmd.Source $destroyShPath $EnvId 2>&1 | ForEach-Object {
            Add-Content -Path $LogFile -Value $_ -Encoding utf8
        }
        return $LASTEXITCODE
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $destroyPs1Path -EnvId $EnvId 2>&1 |
            ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
        return $LASTEXITCODE
    }
}

Write-Daemon "[daemon] starting (interval=${Interval}s, root=$Root)"

# We never raise; one corrupt state file would otherwise take the
# daemon down and quietly leak environments past their TTL.
while ($true) {
    try {
        $now = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $envsDir = Join-Path $Root 'envs'
        if (Test-Path $envsDir) {
            $stateFiles = Get-ChildItem -Path $envsDir -Filter 'env-*.json' -ErrorAction SilentlyContinue
            foreach ($f in $stateFiles) {
                try {
                    $state = Get-Content -Raw $f.FullName | ConvertFrom-Json
                } catch {
                    Write-Daemon "[daemon] WARN: malformed state file $($f.Name) — skipping"
                    continue
                }
                $envId     = $state.id
                $createdAt = [int64]$state.created_at
                $ttl       = [int64]$state.ttl
                if (-not $envId -or -not $createdAt -or -not $ttl) {
                    Write-Daemon "[daemon] WARN: malformed state file $($f.Name) — skipping"
                    continue
                }
                $expiresAt = $createdAt + $ttl
                if ($now -gt $expiresAt) {
                    $age = $now - $createdAt
                    Write-Daemon "[daemon] expiring $envId (age=${age}s, ttl=${ttl}s)"
                    $code = Invoke-Destroy $envId
                    if ($code -eq 0) {
                        Write-Daemon "[daemon] destroyed $envId"
                    } else {
                        Write-Daemon "[daemon] ERROR: destroy failed for $envId (exit=$code)"
                    }
                }
            }
        }
    } catch {
        Write-Daemon "[daemon] ERROR: tick failed: $_"
    }
    Start-Sleep -Seconds $Interval
}
