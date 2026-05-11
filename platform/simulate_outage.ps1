#requires -Version 5.1
<#
.SYNOPSIS
    Chaos toggle for sandbox environments (Windows-native parallel of simulate_outage.sh).

.DESCRIPTION
    Same modes as the bash version: crash, pause, network, recover, stress.
    Same multi-step guard: refuses to touch anything that doesn't look like
    a sandbox env container.

.EXAMPLE
    .\simulate_outage.ps1 -Env env-abc123 -Mode crash
#>
param(
    [Parameter(Mandatory = $true)] [string] $Env,
    [Parameter(Mandatory = $true)] [ValidateSet('crash','pause','network','recover','stress')] [string] $Mode
)

$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $Root

# Write to stderr and exit with the intended code. We can't use Write-Error
# because $ErrorActionPreference='Stop' would convert it into a terminating
# error and the trailing `exit N` would never run — the process would die
# with code 1 instead of N, and the guard test (test.md 6.4) expects N=3.
function Fail([int] $Code, [string] $Message) {
    [Console]::Error.WriteLine($Message)
    exit $Code
}

# --- safety guard: never simulate an outage against platform infrastructure ---
$ProtectedNames    = @('sandbox-nginx','sandbox-api','sandbox-cleanup','sandbox-monitor')
$ProtectedPrefixes = @('sandbox-','nginx','cleanup','monitor','api')

if (-not $Env.StartsWith('env-')) {
    Fail 3 "[outage] REFUSING: env id '$Env' must start with 'env-' (chaos is sandbox-only)"
}
if ($ProtectedNames -contains $Env) {
    Fail 3 "[outage] REFUSING: '$Env' is a protected platform container"
}

$stateFile = Join-Path $Root "envs/$Env.json"
if (-not (Test-Path $stateFile)) {
    Fail 4 "[outage] no such env: $Env"
}

$state = Get-Content -Raw $stateFile | ConvertFrom-Json
$container = [string]$state.container
$network = "$Env-net"
$sharedNet = $env:SHARED_NET
if (-not $sharedNet) { $sharedNet = 'sandbox-net' }

# Re-check after resolving the container name: same logic as the bash
# version's case-glob on prefixes. If the resolved container doesn't
# itself start with env-, it's not a sandbox env and we refuse.
foreach ($p in $ProtectedPrefixes) {
    if ($container -eq $p -or $container -like "$p-*" -or $container -like "${p}_*") {
        if (-not $container.StartsWith('env-')) {
            Fail 3 "[outage] REFUSING: resolved container '$container' looks like infrastructure"
        }
    }
}

# Final guard — the docker label must match. If a previous teardown left
# a stale state file pointing at a recycled container name, we'd otherwise
# nuke whatever happened to inherit that name.
$labelValue = (docker inspect -f '{{ index .Config.Labels "sandbox.env" }}' $container 2>$null)
if ($labelValue -ne $Env) {
    Fail 3 "[outage] REFUSING: container '$container' is not labelled sandbox.env=$Env"
}

function ts { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

switch ($Mode) {
    'crash' {
        Write-Host "[outage] $(ts) ${Env}: docker kill $container"
        docker kill $container *> $null
    }
    'pause' {
        Write-Host "[outage] $(ts) ${Env}: docker pause $container"
        docker pause $container *> $null
    }
    'network' {
        Write-Host "[outage] $(ts) ${Env}: docker network disconnect $network $container"
        docker network disconnect $network $container *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[outage] disconnect from $network failed (already detached?)"
        }
    }
    'recover' {
        $status = (docker inspect -f '{{.State.Status}}' $container 2>$null)
        if (-not $status) { $status = 'missing' }
        switch ($status) {
            'paused' {
                Write-Host "[outage] $(ts) ${Env}: docker unpause $container"
                docker unpause $container *> $null
            }
            { $_ -in 'exited','created' } {
                Write-Host "[outage] $(ts) ${Env}: docker start $container"
                docker start $container *> $null
            }
            'running' {
                Write-Host "[outage] $(ts) ${Env}: container already running"
            }
            'missing' {
                Fail 5 "[outage] container is gone; recreate the env instead"
            }
        }
        # Make sure both networks are reattached — network-mode outage
        # detaches the dedicated net; a kill+recover may have dropped both.
        $attached = (docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}' $container 2>$null) -split ' '
        if ($attached -notcontains $network) {
            docker network connect $network $container *> $null
        }
        if ($attached -notcontains $sharedNet) {
            docker network connect $sharedNet $container *> $null
        }
    }
    'stress' {
        Write-Host "[outage] $(ts) ${Env}: stress-ng --cpu 2 --timeout 60s (background)"
        docker exec $container sh -c 'command -v stress-ng' *> $null
        if ($LASTEXITCODE -eq 0) {
            docker exec -d $container stress-ng --cpu 2 --timeout 60s *> $null
        } else {
            Write-Host "[outage] stress-ng not found in container — running awk busy-loop fallback"
            docker exec -d $container sh -c 'awk "BEGIN{for(i=0;i<1e10;i++);}" &' *> $null
        }
    }
}

Write-Host "[outage] done"
