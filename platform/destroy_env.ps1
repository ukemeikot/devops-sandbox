#requires -Version 5.1
<#
.SYNOPSIS
    Tear down a sandbox environment (Windows-native parallel of destroy_env.sh).
    Order matters: kill the log follower first so it stops writing into a
    directory we're about to archive.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $EnvId
)

$ErrorActionPreference = 'Stop'

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

$NginxContainer = $env:NGINX_CONTAINER
if (-not $NginxContainer) { $NginxContainer = 'sandbox-nginx' }
$SharedNet = $env:SHARED_NET
if (-not $SharedNet) { $SharedNet = 'sandbox-net' }

$StateFile     = Join-Path $Root "envs/$EnvId.json"
$NginxConfPath = Join-Path $Root "nginx/conf.d/$EnvId.conf"
$NetworkName   = "$EnvId-net"

# 1. Kill the log follower BEFORE we remove the container or move logs.
if (Test-Path $StateFile) {
    try {
        $state = Get-Content -Raw $StateFile | ConvertFrom-Json
        $logPid = [int]$state.log_pid
        if ($logPid -gt 0) {
            $proc = Get-Process -Id $logPid -ErrorAction SilentlyContinue
            if ($proc) { Stop-Process -Id $logPid -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-Warning "[destroy] could not parse $StateFile for log_pid: $_"
    }
}

# 2. Remove every container that carries the label. Plural — defensive
#    in case a future extension lets an env have multiple sidecars.
$containers = docker ps -aq --filter "label=sandbox.env=$EnvId"
if ($containers) {
    docker rm -f @($containers) *> $null
}

# 3. Remove the dedicated network. Best-effort; the container removal
#    above already detached from it.
docker network inspect $NetworkName *> $null
if ($LASTEXITCODE -eq 0) {
    docker network rm $NetworkName *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[destroy] failed to remove network $NetworkName"
    }
}

# 4. Drop the nginx config + reload.
if (Test-Path $NginxConfPath) { Remove-Item -Force $NginxConfPath }

$nginxRunning = ((docker ps --format '{{.Names}}') -split "`r?`n") -contains $NginxContainer
if ($nginxRunning) {
    docker exec $NginxContainer nginx -s reload *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[destroy] nginx reload failed"
    }
}

# 5. Archive logs to logs/archived/<env_id>/<utc-ts>/.
$liveLogDir = Join-Path $Root "logs/$EnvId"
if (Test-Path $liveLogDir) {
    $ts = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $archiveDir = Join-Path $Root "logs/archived/$EnvId/$ts"
    New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

    $entries = Get-ChildItem -Path $liveLogDir -Force -ErrorAction SilentlyContinue
    foreach ($e in $entries) {
        try { Move-Item -Path $e.FullName -Destination $archiveDir -Force }
        catch { Write-Warning "[destroy] could not archive $($e.FullName): $_" }
    }
    Remove-Item -Path $liveLogDir -Recurse -Force -ErrorAction SilentlyContinue
}

# 6. Drop the state file LAST so observers (monitor, cleanup daemon, API)
#    see the env vanish atomically — never partway through teardown.
if (Test-Path $StateFile) { Remove-Item -Force $StateFile }

Write-Host "[destroy] env $EnvId destroyed"
