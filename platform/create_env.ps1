#requires -Version 5.1
<#
.SYNOPSIS
    Provision a sandbox environment (Windows-native parallel of create_env.sh).

.DESCRIPTION
    Mirrors the bash version step-for-step so envs created from PowerShell
    are indistinguishable from envs created from bash. The two scripts
    write the same state JSON shape, the same nginx conf shape, and use
    the same docker labels — destroy_env.* and the cleanup daemon don't
    care which side created the env.

.PARAMETER Name
    Human-readable name for the env. Stored in the state file and as a
    docker label.

.PARAMETER Ttl
    Time-to-live in seconds. Defaults to 1800 (30 min).

.EXAMPLE
    .\create_env.ps1 demo 600
    .\create_env.ps1 -Name demo -Ttl 600
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Name,

    [Parameter(Position = 1)]
    [int] $Ttl = 1800
)

$ErrorActionPreference = 'Stop'

# Repo root resolves the same as the bash version: parent of platform/.
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $Root

if ($Ttl -le 0) {
    [Console]::Error.WriteLine("ttl_seconds must be a positive integer")
    exit 2
}

# Tiny .env loader — KEY=VALUE per line, # comments allowed, no expansion.
# Keeping it dependency-free so Windows users don't need a separate module.
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

function Get-Env([string] $Key, $Default) {
    $v = [Environment]::GetEnvironmentVariable($Key, 'Process')
    if ([string]::IsNullOrEmpty($v)) { return $Default } else { return $v }
}

$DemoImage      = Get-Env 'DEMO_IMAGE'      'devops-sandbox/demo-app:latest'
$NginxContainer = Get-Env 'NGINX_CONTAINER' 'sandbox-nginx'
$SharedNet      = Get-Env 'SHARED_NET'      'sandbox-net'
$AppPort        = [int](Get-Env 'APP_PORT'  '8080')

# 6 chars of lower-alnum, same shape as the bash version's tr-from-urandom.
$alphabet = (48..57) + (97..122) | ForEach-Object { [char]$_ }
$EnvId          = 'env-' + (-join (1..6 | ForEach-Object { Get-Random -InputObject $alphabet }))
$ContainerName  = $EnvId
$NetworkName    = "$EnvId-net"

New-Item -ItemType Directory -Force -Path `
    (Join-Path $Root 'envs'), `
    (Join-Path $Root "logs/$EnvId"), `
    (Join-Path $Root 'nginx/conf.d') | Out-Null

# Build the demo image lazily so a freshly cloned repo works without a
# separate `make demo-image` step.
docker image inspect $DemoImage *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[create] building demo image $DemoImage ..."
    docker build -q -t $DemoImage (Join-Path $Root 'platform/demo-app') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
}

# Ensure the shared network exists, then create the dedicated per-env one.
docker network inspect $SharedNet *> $null
if ($LASTEXITCODE -ne 0) { docker network create $SharedNet | Out-Null }

docker network create $NetworkName | Out-Null
if ($LASTEXITCODE -ne 0) { throw "docker network create $NetworkName failed" }

docker run -d `
    --name $ContainerName `
    --hostname $ContainerName `
    --network $NetworkName `
    --label "sandbox.env=$EnvId" `
    --label "sandbox.role=app" `
    --label "sandbox.name=$Name" `
    -e "ENV_ID=$EnvId" `
    -e "ENV_NAME=$Name" `
    $DemoImage | Out-Null
if ($LASTEXITCODE -ne 0) { throw "docker run failed for $ContainerName" }

docker network connect $SharedNet $ContainerName | Out-Null
if ($LASTEXITCODE -ne 0) { throw "could not attach $ContainerName to $SharedNet" }

# Per-env nginx location block. Backtick-escapes prevent PowerShell from
# eating the literal nginx variables ($host, $remote_addr, …).
$nginxConfBody = @"
# Auto-generated for $EnvId ($Name) — do not edit by hand.
location /env/$EnvId/ {
    proxy_pass         http://${ContainerName}:$AppPort/;
    proxy_set_header   Host `$host;
    proxy_set_header   X-Real-IP `$remote_addr;
    proxy_set_header   X-Forwarded-For `$proxy_add_x_forwarded_for;
    proxy_set_header   X-Sandbox-Env $EnvId;
    proxy_read_timeout 30s;
}
"@

$nginxConfPath = Join-Path $Root "nginx/conf.d/$EnvId.conf"
$tmpConfPath = [System.IO.Path]::GetTempFileName()
# BOM-less UTF-8 so nginx never has to tolerate a BOM on a .conf snippet.
[System.IO.File]::WriteAllText(
    $tmpConfPath,
    $nginxConfBody,
    (New-Object System.Text.UTF8Encoding($false))
)
Move-Item -Path $tmpConfPath -Destination $nginxConfPath -Force

# Reload nginx. Skip-with-warning if the proxy isn't up so the env is
# still usable once the operator brings nginx online later.
$nginxRunning = ((docker ps --format '{{.Names}}') -split "`r?`n") -contains $NginxContainer
if ($nginxRunning) {
    docker exec $NginxContainer nginx -s reload *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[create] nginx reload failed for $EnvId"
    }
} else {
    Write-Warning "[create] nginx container '$NginxContainer' not running; route registered but not yet served"
}

# Log shipping — detached docker logs follower (Approach A). The hidden
# window means the child outlives this script even when invoked from a
# console that closes immediately afterwards.
$LogFile    = Join-Path $Root "logs/$EnvId/app.log"
$LogErrFile = Join-Path $Root "logs/$EnvId/app.log.err"

$followerProc = Start-Process -FilePath 'docker' `
    -ArgumentList @('logs', '-f', $ContainerName) `
    -RedirectStandardOutput $LogFile `
    -RedirectStandardError  $LogErrFile `
    -WindowStyle Hidden `
    -PassThru
$LogPid = $followerProc.Id

# Atomic state file write. Same shape as the bash version.
$CreatedAt = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())

# Hand-rolled JSON so the produced shape matches the bash heredoc byte-
# for-byte (ConvertTo-Json in 5.1 mangles integer types and key order).
$stateJson = @"
{
  "id": "$EnvId",
  "name": "$Name",
  "created_at": $CreatedAt,
  "ttl": $Ttl,
  "status": "running",
  "container": "$ContainerName",
  "network": "$NetworkName",
  "shared_network": "$SharedNet",
  "app_port": $AppPort,
  "log_pid": $LogPid,
  "consecutive_failures": 0,
  "url": "http://localhost/env/$EnvId/"
}
"@

$stateFile = Join-Path $Root "envs/$EnvId.json"
$tmpStatePath = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText(
    $tmpStatePath,
    $stateJson,
    (New-Object System.Text.UTF8Encoding($false))
)
Move-Item -Path $tmpStatePath -Destination $stateFile -Force

$ExpiresAt = [DateTimeOffset]::FromUnixTimeSeconds($CreatedAt + $Ttl).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Host "[create] env_id : $EnvId"
Write-Host "[create] name   : $Name"
Write-Host "[create] url    : http://localhost/env/$EnvId/"
Write-Host "[create] ttl    : ${Ttl}s (expires $ExpiresAt)"
