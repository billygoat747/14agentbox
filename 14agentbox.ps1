# ==============================================================================
# 14agentbox: Windows PowerShell Runner
# Provides:
# - Zero-Trust Host Credential Proxying
# - Persistent Basebox with Smart Delta Project Caching
# - Per-(Folder + Git Branch) Host Session Isolation
# - Ephemeral Container Lifecycle (--rm)
# ==============================================================================
param (
    [switch]$Init,
    [switch]$BuildBase,
    [switch]$Clean,
    [switch]$Sessions,
    [switch]$DirectEnv,
    [switch]$ProxyLogRequests,
    [string]$TargetDir = "",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Command
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# NOTE: Windows PowerShell 5.1 has no $PSNativeCommandUseErrorActionPreference
# (PS 7.4+ only), so native-command probing must be wrapped explicitly.
# Invoke-NativeProbe runs a native command (git/docker) whose non-zero exit
# or stderr output is expected and must NOT abort the script. Returns the
# command output; caller checks $LASTEXITCODE afterwards.
function Invoke-NativeProbe([scriptblock]$Probe) {
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try { & $Probe } finally { $ErrorActionPreference = $oldEAP }
}

# Assert-LastExitCode aborts with a clear message when the previous native
# command failed. Call immediately after docker build/tag/network commands.
function Assert-LastExitCode([string]$Message) {
    if ($LASTEXITCODE -ne 0) {
        Write-Error $Message
        exit 1
    }
}

# 1. Handle Utilities
if ($Init) {
    $ResolveTarget = if ($TargetDir) { (Resolve-Path -LiteralPath $TargetDir).Path } else { (Get-Location).Path }
    $InitFile = Join-Path $ResolveTarget "14agentbox.json"
    if (Test-Path $InitFile) {
        Write-Error "[14agentbox] Error: $InitFile already exists."
        exit 1
    }
    $Template = @'
{
  "$schema": "https://raw.githubusercontent.com/billygoat747/14agentbox/main/14agentbox.schema.json",
  "ports": [],
  "network": "",
  "compose_services": [],
  "forward_ports": [],
  "env": {}
}
'@
    Set-Content -Path $InitFile -Value $Template -Encoding UTF8
    Write-Host "[14agentbox] Initialized $InitFile"
    exit 0
}

if ($BuildBase) {
    Write-Host "[14agentbox] Building persistent basebox..."
    $Commit = Invoke-NativeProbe { git -C "$ScriptDir" rev-parse --short HEAD 2>$null }
    if (-not $Commit) { $Commit = "latest" }
    $BaseTag = "14agentbox:base-${Commit}"
    docker build -t "$BaseTag" "$ScriptDir"
    Assert-LastExitCode "[14agentbox] Basebox image build failed."
    docker tag "$BaseTag" "14agentbox:base"
    Assert-LastExitCode "[14agentbox] Failed to tag basebox image."
    Write-Host "[14agentbox] Basebox successfully built: $BaseTag"
    exit 0
}

$SessBase = "$env:USERPROFILE\.14agentbox\sessions"

if ($Sessions) {
    Write-Host "[14agentbox] Cached project sessions in $SessBase :"
    if (Test-Path $SessBase) {
        Get-ChildItem -Path $SessBase -Recurse -Depth 2 | Select-Object FullName
    } else {
        Write-Host "No active sessions found."
    }
    exit 0
}

# PowerShell binds the first bare argument to -TargetDir, so `14agentbox opencode`
# would treat "opencode" as a path. Like the bash runner, only accept it as the
# project directory if it exists; otherwise it is the start of the command.
if ($TargetDir -and -not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
    $Command = @($TargetDir) + @($Command | Where-Object { $_ })
    $TargetDir = ""
}

# Resolve target project directory
if (-not $TargetDir) {
    $TargetDir = (Get-Location).Path
} else {
    $TargetDir = (Resolve-Path -LiteralPath $TargetDir).Path
}

$ProjectName = Split-Path -Leaf $TargetDir
$NormalizedPath = $TargetDir.Replace('\', '/').ToLower()
$Sha256 = [System.Security.Cryptography.SHA256]::Create()
$PathHashBytes = $Sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($NormalizedPath))
$PathHash = ([System.BitConverter]::ToString($PathHashBytes) -replace '-').ToLower().Substring(0, 10)

$BranchName = Invoke-NativeProbe { git -C "$TargetDir" rev-parse --abbrev-ref HEAD 2>$null }
if (-not $BranchName) { $BranchName = "default" }
$SafeBranch = $BranchName -replace '[^a-zA-Z0-9._-]', '_'

if ($Clean) {
    $CleanDir = "$SessBase\${ProjectName}-${PathHash}\${SafeBranch}"
    if (Test-Path $CleanDir) {
        Remove-Item -Recurse -Force $CleanDir
        Write-Host "[14agentbox] Cleaned session cache: $CleanDir"
    } else {
        Write-Host "[14agentbox] No session cache found at $CleanDir"
    }
    exit 0
}

# 2. Basebox & Smart Delta Image Resolution
$BoxCommit = Invoke-NativeProbe { git -C "$ScriptDir" rev-parse --short HEAD 2>$null }
if (-not $BoxCommit) { $BoxCommit = "latest" }
$BaseTag = "14agentbox:base-${BoxCommit}"

$null = Invoke-NativeProbe { docker image inspect "$BaseTag" 2>$null }
if ($LASTEXITCODE -ne 0) {
    Write-Host "[14agentbox] Basebox image not found. Building ($BaseTag)..."
    docker build -t "$BaseTag" "$ScriptDir"
    Assert-LastExitCode "[14agentbox] Basebox image build failed."
    docker tag "$BaseTag" "14agentbox:base"
    Assert-LastExitCode "[14agentbox] Failed to tag basebox image."
}

$ProjDocker = Join-Path $TargetDir "14agentbox.Dockerfile"
if (Test-Path $ProjDocker) {
    $DockerContent = Get-Content -Raw -Path $ProjDocker
    $DockerHashBytes = $Sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($DockerContent))
    $DockerHash = ([System.BitConverter]::ToString($DockerHashBytes) -replace '-').ToLower().Substring(0, 10)
    $ImageTag = "14agentbox-${ProjectName}:${BoxCommit}-${DockerHash}"

    $null = Invoke-NativeProbe { docker image inspect "$ImageTag" 2>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[14agentbox] Building project delta layer on top of basebox ($ImageTag)..."
        docker build --build-arg BASE_IMAGE="$BaseTag" -f "$ProjDocker" -t "$ImageTag" "$TargetDir"
        Assert-LastExitCode "[14agentbox] Project image build failed."
    } else {
        Write-Host "[14agentbox] Using cached project image ($ImageTag)"
    }
} else {
    $ImageTag = $BaseTag
}

# 3. Parse Downstream 14agentbox.json
$DockerArgs = @()
$ForwardRules = ""
$ProjJson = Join-Path $TargetDir "14agentbox.json"

if (Test-Path $ProjJson) {
    $Config = Get-Content -Raw -Path $ProjJson | ConvertFrom-Json
    if ($Config.ports) {
        foreach ($p in $Config.ports) { $DockerArgs += @("-p", $p) }
    }
    if ($Config.network) {
        $null = Invoke-NativeProbe { docker network inspect $Config.network 2>$null }
        if ($LASTEXITCODE -ne 0) {
            Invoke-NativeProbe { docker network create --label "com.docker.compose.network=default" --label "com.docker.compose.project=$ProjectName" $Config.network 2>$null } | Out-Null
        }
        $DockerArgs += @("--network", $Config.network)
    }
    if ($Config.links) {
        foreach ($l in $Config.links) { $DockerArgs += @("--link", $l) }
    }
    if ($Config.extra_hosts) {
        foreach ($h in $Config.extra_hosts) { $DockerArgs += @("--add-host", $h) }
    }
    if ($Config.forward_ports) {
        $ForwardRules = ($Config.forward_ports -join ",")
        $DockerArgs += @("-e", "AGENTBOX_FORWARD_PORTS=$ForwardRules")
    }
    if ($Config.env) {
        foreach ($prop in $Config.env.PSObject.Properties) {
            $DockerArgs += @("-e", "$($prop.Name)=$($prop.Value)")
        }
    }
    if ($Config.compose_services -and (Test-Path "$TargetDir\docker-compose.yml")) {
        Write-Host "[14agentbox] Starting project compose dependencies ($($Config.compose_services -join ' '))..."
        docker compose -f "$TargetDir\docker-compose.yml" up -d $Config.compose_services
    }
}

# 4. Zero-Trust Host Credential Proxy
$ProxyProcess = $null
$EnvFile = Join-Path $ScriptDir ".env"

try {
    if (-not $DirectEnv -and (Test-Path $EnvFile)) {
        Write-Host "[14agentbox] Starting Zero-Trust Credential Proxy on host..."
        # Keep proxy stdout/stderr out of the interactive console (they would
        # stomp full-screen TUIs like OpenCode). PS 5.1 Start-Process requires
        # distinct redirect files, and logs live under $env:TEMP so the repo
        # checkout stays clean (*.log is also gitignored as a backstop).
        $ProxyLogDir = Join-Path $env:TEMP "14agentbox"
        New-Item -ItemType Directory -Force -Path $ProxyLogDir | Out-Null
        $ProxyLog = Join-Path $ProxyLogDir "proxy.log"
        $ProxyErrLog = Join-Path $ProxyLogDir "proxy.err.log"
        $ProxyArgs = "`"$ScriptDir\proxy.py`" --env-file `"$EnvFile`" --port 8040"
        if ($ProxyLogRequests) { $ProxyArgs += " --log-requests" }
        $ProxyProcess = Start-Process -FilePath "python" `
            -ArgumentList $ProxyArgs `
            -RedirectStandardOutput "$ProxyLog" `
            -RedirectStandardError "$ProxyErrLog" `
            -PassThru -NoNewWindow
        # Python cold starts on Windows can take several seconds (e.g. AV scans).
        # The container's entrypoint discovers providers/models from the proxy, so
        # it must be listening before the container starts.
        $ProxyReady = $false
        $Deadline = (Get-Date).AddSeconds(20)
        while (-not $ProxyReady -and (Get-Date) -lt $Deadline -and -not $ProxyProcess.HasExited) {
            try {
                $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 "http://127.0.0.1:8040/health"
                $ProxyReady = $true
            } catch {
                Start-Sleep -Milliseconds 200
            }
        }
        if (-not $ProxyReady) {
            Write-Warning "[14agentbox] Credential proxy is not responding on port 8040 (see $ProxyErrLog)."
        }
    } elseif ($DirectEnv -and (Test-Path $EnvFile)) {
        Write-Host "[14agentbox] Direct environment mode active."
        $DockerArgs += @("--env-file", $EnvFile)
    }

    # 5. Session Mounts (Folder + Git Branch)
    $SessionDir = "$SessBase\${ProjectName}-${PathHash}\${SafeBranch}"
    New-Item -ItemType Directory -Force -Path "$SessionDir\opencode" | Out-Null
    New-Item -ItemType Directory -Force -Path "$SessionDir\antigravity" | Out-Null
    if (-not (Test-Path "$SessionDir\bash_history")) {
        New-Item -ItemType File -Force -Path "$SessionDir\bash_history" | Out-Null
    }

    Write-Host "[14agentbox] Launching devbox for $ProjectName (branch: $SafeBranch)"

    # 6. Execute Ephemeral Container (--rm)
    $ContainerName = "14agentbox-${ProjectName}-${SafeBranch}-$PID"
    $ExecCmd = if ($Command -and $Command.Count -gt 0) { $Command } else { @("/bin/bash") }

    docker run --rm -it `
        --name "$ContainerName" `
        --add-host host.docker.internal:host-gateway `
        -e TERM=xterm-256color `
        -e COLORTERM=truecolor `
        -v "${TargetDir}:/workspace" `
        -v "${SessionDir}\opencode:/home/dev/.local" `
        -v "${SessionDir}\antigravity:/home/dev/.gemini" `
        -v "${SessionDir}\bash_history:/home/dev/.bash_history" `
        $DockerArgs `
        "$ImageTag" `
        $ExecCmd

} finally {
    if ($ProxyProcess -and -not $ProxyProcess.HasExited) {
        Stop-Process -Id $ProxyProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($Config.compose_services -and (Test-Path "$TargetDir\docker-compose.yml")) {
        Write-Host "[14agentbox] Tearing down project compose dependencies..."
        Invoke-NativeProbe { docker compose -f "$TargetDir\docker-compose.yml" down --remove-orphans 2>$null } | Out-Null
    }
}
