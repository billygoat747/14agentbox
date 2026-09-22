# ==============================================================================
# 14agentbox: Windows PowerShell Runner
# Provides:
# - Zero-Trust Host Credential Proxying
# - Persistent Basebox with Smart Delta Project Caching
# - Per-(Folder + Git Branch) Host Session Isolation
# - Ephemeral Container Lifecycle (--rm)
# ==============================================================================
param (
    [switch]$BuildBase,
    [switch]$Clean,
    [switch]$Sessions,
    [switch]$DirectEnv,
    [string]$TargetDir = "",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Command
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 1. Handle Utilities
if ($BuildBase) {
    Write-Host "[14agentbox] Building persistent basebox..."
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $Commit = git -C "$ScriptDir" rev-parse --short HEAD 2>$null
    $ErrorActionPreference = $oldEAP
    if (-not $Commit) { $Commit = "latest" }
    $BaseTag = "14agentbox:base-${Commit}"
    docker build -t "$BaseTag" "$ScriptDir"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "[14agentbox] Basebox image build failed."
        exit 1
    }
    docker tag "$BaseTag" "14agentbox:base"
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

$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$BranchName = git -C "$TargetDir" rev-parse --abbrev-ref HEAD 2>$null
$ErrorActionPreference = $oldEAP
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
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$BoxCommit = git -C "$ScriptDir" rev-parse --short HEAD 2>$null
if (-not $BoxCommit) { $BoxCommit = "latest" }
$BaseTag = "14agentbox:base-${BoxCommit}"

$BaseInspect = docker image inspect "$BaseTag" 2>$null
$ErrorActionPreference = $oldEAP
if ($LASTEXITCODE -ne 0) {
    Write-Host "[14agentbox] Basebox image not found. Building ($BaseTag)..."
    docker build -t "$BaseTag" "$ScriptDir"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "[14agentbox] Basebox image build failed."
        exit 1
    }
    docker tag "$BaseTag" "14agentbox:base"
}

$ProjDocker = Join-Path $TargetDir "14agentbox.Dockerfile"
if (Test-Path $ProjDocker) {
    $DockerContent = Get-Content -Raw -Path $ProjDocker
    $DockerHashBytes = $Sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($DockerContent))
    $DockerHash = ([System.BitConverter]::ToString($DockerHashBytes) -replace '-').ToLower().Substring(0, 10)
    $ImageTag = "14agentbox-${ProjectName}:${BoxCommit}-${DockerHash}"

    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $ProjInspect = docker image inspect "$ImageTag" 2>$null
    $ErrorActionPreference = $oldEAP
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[14agentbox] Building project delta layer on top of basebox ($ImageTag)..."
        docker build --build-arg BASE_IMAGE="$BaseTag" -f "$ProjDocker" -t "$ImageTag" "$TargetDir"
        if ($LASTEXITCODE -ne 0) {
            Write-Error "[14agentbox] Project image build failed."
            exit 1
        }
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
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $null = docker network inspect $Config.network 2>$null
        $ErrorActionPreference = $oldEAP
        if ($LASTEXITCODE -ne 0) {
            $oldEAP = $ErrorActionPreference
            $ErrorActionPreference = "SilentlyContinue"
            docker network create --label "com.docker.compose.network=default" --label "com.docker.compose.project=$ProjectName" $Config.network 2>$null | Out-Null
            $ErrorActionPreference = $oldEAP
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
        $ProxyLog = Join-Path $ScriptDir "proxy.log"
        $ProxyErrLog = Join-Path $ScriptDir "proxy.err.log"
        $ProxyProcess = Start-Process -FilePath "python" `
            -ArgumentList "`"$ScriptDir\proxy.py`" --env-file `"$EnvFile`" --port 8040" `
            -RedirectStandardOutput "$ProxyLog" `
            -RedirectStandardError "$ProxyErrLog" `
            -PassThru -NoNewWindow
        Start-Sleep -Milliseconds 400
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
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        docker compose -f "$TargetDir\docker-compose.yml" down --remove-orphans 2>$null | Out-Null
        $ErrorActionPreference = $oldEAP
    }
}
