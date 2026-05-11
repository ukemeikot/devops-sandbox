#requires -Version 5.1
<#
.SYNOPSIS
    Windows-native operator UX for the sandbox platform.

.DESCRIPTION
    Mirrors the Makefile verb-for-verb. Use this when running on bare
    Windows PowerShell. On Linux / macOS / WSL2 / Git Bash, use `make`
    against the Makefile instead — both drive the same scripts and
    produce the same on-disk state, so a platform brought up by one can
    be operated by the other.

    Verbs:
        help                          show this help
        up                            start nginx, daemon, monitor, API
        down                          destroy every env, stop everything
        restart                       down + up
        create [-Name x] [-Ttl 600]   create one env (prompts if -Name omitted)
        destroy -Env env-xxxxxx       destroy a specific env
        list                          active envs with TTL remaining
        logs -Env env-xxxxxx          tail an env's app log
        health                        latest health line per env
        simulate -Env x -Mode crash   trigger an outage simulation
        clean                         destroy all envs, wipe state/logs
        install                       pip install Python deps
        demo-image                    build the bundled demo app image

    Override defaults inline:
        .\make.ps1 create -Name demo -Ttl 600
        .\make.ps1 destroy -Env env-abc123
        .\make.ps1 simulate -Env env-abc123 -Mode crash
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Verb = 'help',

    [string] $Name,
    [int]    $Ttl  = 1800,
    [string] $Env,
    [string] $Mode
)

$ErrorActionPreference = 'Stop'

$Root        = $PSScriptRoot
$PlatformDir = Join-Path $Root 'platform'
$MonitorDir  = Join-Path $Root 'monitor'
$EnvsDir     = Join-Path $Root 'envs'
$LogsDir     = Join-Path $Root 'logs'
$DaemonPid   = Join-Path $LogsDir 'cleanup_daemon.pid'
$MonPid      = Join-Path $LogsDir 'monitor.pid'
$ApiPid      = Join-Path $LogsDir 'api.pid'

# Load .env so DEMO_IMAGE / SHARED_NET / NGINX_HOST_PORT / API_PORT propagate.
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

function Get-EnvOr([string] $Key, $Default) {
    $v = [Environment]::GetEnvironmentVariable($Key, 'Process')
    if ([string]::IsNullOrEmpty($v)) { return $Default } else { return $v }
}

$NginxHostPort = Get-EnvOr 'NGINX_HOST_PORT' '80'
$ApiPort       = Get-EnvOr 'API_PORT'        '5000'
$DemoImage     = Get-EnvOr 'DEMO_IMAGE'      'devops-sandbox/demo-app:latest'

function Resolve-Python {
    # Windows ships "App Execution Alias" stubs at
    # %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe (and python3.exe).
    # They are zero-byte shortcuts that open the Microsoft Store — running
    # them prints "Python was not found ..." and exits non-zero. Skip them
    # or `pip install` blows up with no useful hint.
    $isStub = { param($c) $c.Source -like '*\WindowsApps\*' }

    # py.exe (Python Launcher) is the most reliable on Windows — it ships
    # with python.org installs and resolves to a real interpreter.
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py -and -not (& $isStub $py)) { return $py.Source }

    foreach ($name in 'python3','python') {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and -not (& $isStub $cmd)) { return $cmd.Source }
    }

    throw @"
No working Python interpreter found.

If you saw "Python was not found; run without arguments to install from the
Microsoft Store", the App Execution Alias is hijacking python.exe / python3.exe
without a real Python being installed.

Install Python:
  winget install --id Python.Python.3.12 -e
or download from https://python.org (tick "Add python.exe to PATH").

Then close and reopen PowerShell so PATH refreshes, and rerun.
"@
}
$PythonExe = Resolve-Python

function Ensure-Dirs {
    foreach ($d in @($EnvsDir, $LogsDir, (Join-Path $LogsDir 'archived'),
                     (Join-Path $LogsDir 'nginx'), (Join-Path $Root 'nginx/conf.d'))) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
}

function Is-Running([string] $PidFile) {
    if (-not (Test-Path $PidFile)) { return $false }
    $existing = (Get-Content -Raw $PidFile).Trim()
    if (-not $existing) { return $false }
    return [bool](Get-Process -Id ([int]$existing) -ErrorAction SilentlyContinue)
}

function Start-Bg([string] $Label, [string] $PidFile, [string] $LogFile, [string] $FilePath, [string[]] $ArgList) {
    if (Is-Running $PidFile) {
        $existing = (Get-Content -Raw $PidFile).Trim()
        Write-Host "[$Label] already running (pid $existing)"
        return
    }
    New-Item -ItemType File -Force -Path $LogFile | Out-Null
    # -WindowStyle Hidden detaches from the console so the process
    # outlives the PowerShell that started it. We do NOT use Start-Job
    # because jobs die with the host.
    $proc = Start-Process -FilePath $FilePath `
        -ArgumentList $ArgList `
        -RedirectStandardOutput $LogFile `
        -RedirectStandardError "$LogFile.err" `
        -WindowStyle Hidden `
        -PassThru
    Set-Content -Path $PidFile -Value $proc.Id -Encoding ascii
    Write-Host "[$Label] started (pid $($proc.Id))"
}

function Stop-Bg([string] $Label, [string] $PidFile) {
    if (-not (Test-Path $PidFile)) { return }
    $existing = (Get-Content -Raw $PidFile).Trim()
    if ($existing) {
        $proc = Get-Process -Id ([int]$existing) -ErrorAction SilentlyContinue
        if ($proc) { Stop-Process -Id ([int]$existing) -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -Force $PidFile -ErrorAction SilentlyContinue
    Write-Host "[$Label] stopped (pid $existing)"
}

function Build-DemoImage {
    Write-Host "[demo-image] building $DemoImage ..."
    docker build -t $DemoImage (Join-Path $PlatformDir 'demo-app') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'docker build failed' }
}

function Verb-Help {
    @"
Usage:  .\make.ps1 <verb> [options]

  help                          show this help
  up                            start nginx + daemon + monitor + API
  down                          destroy every env, stop everything
  restart                       down + up
  create [-Name x] [-Ttl 600]   create an env (prompts if -Name omitted)
  destroy -Env env-xxxxxx       destroy a specific env
  list                          active envs + TTL remaining
  logs -Env env-xxxxxx          tail an env's app log (Ctrl-C to stop)
  health                        latest health line per env
  simulate -Env x -Mode crash   trigger an outage (crash|pause|network|recover|stress)
  clean                         destroy all envs, wipe state + logs + archives
  install                       pip install Python deps
  demo-image                    docker build the bundled demo app
"@ | Write-Host
}

function Verb-Install {
    Ensure-Dirs
    & $PythonExe -m pip install -q -r (Join-Path $PlatformDir 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }
}

function Verb-Up {
    Ensure-Dirs
    Build-DemoImage
    docker compose up -d nginx
    if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed' }

    Start-Bg 'daemon'  $DaemonPid (Join-Path $LogsDir 'cleanup.log') `
        'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                       (Join-Path $PlatformDir 'cleanup_daemon.ps1'))

    Start-Bg 'monitor' $MonPid (Join-Path $LogsDir 'monitor.log') `
        $PythonExe @((Join-Path $MonitorDir 'health_monitor.py'))

    Start-Bg 'api'     $ApiPid (Join-Path $LogsDir 'api.log') `
        $PythonExe @((Join-Path $PlatformDir 'api.py'))

    Write-Host ''
    Write-Host '  [up] platform ready:'
    Write-Host "       nginx     -> http://localhost:$NginxHostPort/"
    Write-Host "       api       -> http://localhost:$ApiPort/envs"
    if (Test-Path $DaemonPid) { Write-Host "       daemon    -> pid $((Get-Content -Raw $DaemonPid).Trim())" }
    if (Test-Path $MonPid)    { Write-Host "       monitor   -> pid $((Get-Content -Raw $MonPid).Trim())" }
}

function Destroy-All {
    if (-not (Test-Path $EnvsDir)) { return }
    $stateFiles = Get-ChildItem -Path $EnvsDir -Filter 'env-*.json' -ErrorAction SilentlyContinue
    foreach ($f in $stateFiles) {
        try {
            $state = Get-Content -Raw $f.FullName | ConvertFrom-Json
            Write-Host "[clean] destroying $($state.id)"
            & powershell -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $PlatformDir 'destroy_env.ps1') -EnvId $state.id | Out-Null
        } catch {
            Write-Warning "[clean] could not destroy from $($f.Name): $_"
        }
    }
}

function Verb-Down {
    Destroy-All
    Stop-Bg 'api'     $ApiPid
    Stop-Bg 'daemon'  $DaemonPid
    Stop-Bg 'monitor' $MonPid
    docker compose down --remove-orphans *> $null
    Write-Host '[down] platform stopped'
}

function Verb-Restart { Verb-Down; Verb-Up }

function Verb-Create {
    Ensure-Dirs
    $n = $Name
    $t = $Ttl
    if (-not $n) {
        $n = Read-Host 'name'
        $rawTtl = Read-Host 'ttl seconds [1800]'
        if ($rawTtl) { $t = [int]$rawTtl }
    }
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PlatformDir 'create_env.ps1') $n $t
    if ($LASTEXITCODE -ne 0) { throw 'create_env failed' }
}

function Verb-Destroy {
    if (-not $Env) { throw 'Usage: .\make.ps1 destroy -Env env-...' }
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PlatformDir 'destroy_env.ps1') -EnvId $Env
}

function Verb-List {
    if (-not (Test-Path $EnvsDir)) { Write-Host '(no active envs)'; return }
    $stateFiles = Get-ChildItem -Path $EnvsDir -Filter 'env-*.json' -ErrorAction SilentlyContinue
    if (-not $stateFiles) { Write-Host '(no active envs)'; return }
    $now = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    foreach ($f in $stateFiles) {
        try {
            $s = Get-Content -Raw $f.FullName | ConvertFrom-Json
            $rem = [int64]$s.created_at + [int64]$s.ttl - $now
            if ($rem -lt 0) { $rem = 0 }
            ('{0,-18} {1,-12} ttl_remaining={2,-5}s status={3}' -f `
                $s.id, $s.name, $rem, $s.status) | Write-Host
        } catch {
            Write-Warning "skipping unreadable $($f.Name): $_"
        }
    }
}

function Verb-Logs {
    if (-not $Env) { throw 'Usage: .\make.ps1 logs -Env env-...' }
    $log = Join-Path $LogsDir "$Env/app.log"
    if (-not (Test-Path $log)) { Write-Host "no logs for $Env"; exit 1 }
    Get-Content -Path $log -Tail 100 -Wait
}

function Verb-Health {
    if (-not (Test-Path $EnvsDir)) { Write-Host '(no active envs)'; return }
    $stateFiles = Get-ChildItem -Path $EnvsDir -Filter 'env-*.json' -ErrorAction SilentlyContinue
    if (-not $stateFiles) { Write-Host '(no active envs)'; return }
    foreach ($f in $stateFiles) {
        try {
            $s = Get-Content -Raw $f.FullName | ConvertFrom-Json
            $lastLine = ''
            $healthLog = Join-Path $LogsDir "$($s.id)/health.log"
            if (Test-Path $healthLog) { $lastLine = (Get-Content -Tail 1 $healthLog) }
            ('{0,-18} status={1,-9} failures={2,-2} last="{3}"' -f `
                $s.id, $s.status, $s.consecutive_failures, $lastLine) | Write-Host
        } catch {
            Write-Warning "skipping unreadable $($f.Name): $_"
        }
    }
}

function Verb-Simulate {
    if (-not $Env -or -not $Mode) {
        throw 'Usage: .\make.ps1 simulate -Env env-... -Mode crash|pause|network|recover|stress'
    }
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PlatformDir 'simulate_outage.ps1') -Env $Env -Mode $Mode
}

function Verb-Clean {
    Destroy-All
    foreach ($p in @(
        (Join-Path $LogsDir '*'),
        (Join-Path $EnvsDir '*.json'),
        (Join-Path $Root 'nginx/conf.d/*.conf'))) {
        Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host '[clean] state, logs, archives, generated nginx configs wiped'
}

function Verb-DemoImage { Build-DemoImage }

switch ($Verb) {
    'help'       { Verb-Help }
    'up'         { Verb-Up }
    'down'       { Verb-Down }
    'restart'    { Verb-Restart }
    'create'     { Verb-Create }
    'destroy'    { Verb-Destroy }
    'list'       { Verb-List }
    'logs'       { Verb-Logs }
    'health'     { Verb-Health }
    'simulate'   { Verb-Simulate }
    'clean'      { Verb-Clean }
    'install'    { Verb-Install }
    'demo-image' { Verb-DemoImage }
    default {
        Write-Host "Unknown verb: $Verb"
        Verb-Help
        exit 2
    }
}
