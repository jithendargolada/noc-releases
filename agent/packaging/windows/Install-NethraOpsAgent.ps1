<#
.SYNOPSIS
    Installs the NethraOps agent as a Windows Service.

.DESCRIPTION
    Sets up:
      - C:\Program Files\NethraOpsAgent\venv     (Python venv with the agent)
      - C:\ProgramData\NethraOpsAgent\agent.env  (config template)
      - C:\ProgramData\NethraOpsAgent\           (state + buffer)
      - "NethraOpsAgent" Windows Service (autostart, recovery: restart on
        first/second/third failure)

    Idempotent - safe to re-run for upgrades. The service is stopped
    before the venv is rebuilt, then re-started.

    Requires:
      - Run as Administrator (UAC elevated)
      - Python 3.11+ available on PATH (or pass -PythonPath)

.PARAMETER BackendUrl
    Backend base URL (e.g. https://monitor.acme.com). Written to
    agent.env on first install.

.PARAMETER EnrolmentToken
    One-shot enrolment token. The agent self-registers on first start
    and persists the long-lived agent token to state.json.

.PARAMETER AgentToken
    Long-lived agent token (skip if using EnrolmentToken).

.PARAMETER DeviceSlug
    Stable device slug. Defaults to the lowercase machine name.

.PARAMETER PythonPath
    Path to the Python interpreter used to bootstrap the venv.
    Defaults to "python".

.EXAMPLE
    PS> .\Install-NethraOpsAgent.ps1 `
            -BackendUrl https://monitor.acme.com `
            -EnrolmentToken acmeXXXXXXXX `
            -DeviceSlug db-east-01

.NOTES
    Phase 2B-7 - pairs with the Linux installer at
    packaging/linux/install.sh. Both target the same `nethraops_agent`
    Python package and produce the same runtime behaviour.
#>

[CmdletBinding()]
param(
    [string] $BackendUrl     = "https://monitor.example.com",
    [string] $EnrolmentToken = "",
    [string] $AgentToken     = "",
    [string] $DeviceSlug     = "",
    [string] $DeviceName     = "",
    [string] $PythonPath     = "python",
    [string] $InstallRoot    = "C:\Program Files\NethraOpsAgent",
    [string] $DataRoot       = "C:\ProgramData\NethraOpsAgent",
    [switch] $SkipServiceStart
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ServiceName = "NethraOpsAgent"
$DisplayName = "NethraOps Agent"

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Install-NethraOpsAgent.ps1 must be run as Administrator."
    }
}

function Get-DefaultDeviceSlug {
    return ($env:COMPUTERNAME).ToLowerInvariant()
}

function New-VenvIfMissing {
    param([string]$VenvPath, [string]$Python)
    if (-not (Test-Path $VenvPath)) {
        Write-Host "==> creating Python venv at $VenvPath"
        & $Python -m venv $VenvPath
        if ($LASTEXITCODE -ne 0) { throw "venv creation failed" }
    }
}

function Install-AgentPackage {
    param([string]$VenvPath, [string]$SourceDir)
    $venvPython = Join-Path $VenvPath "Scripts\python.exe"
    Write-Host "==> upgrading pip / wheel"
    & $venvPython -m pip install --upgrade pip wheel | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed" }
    Write-Host "==> installing nethraops-agent + windows extras"
    & $venvPython -m pip install "$SourceDir[windows]"
    if ($LASTEXITCODE -ne 0) { throw "agent install failed" }
}

function Write-EnvFileIfMissing {
    param([string]$EnvFile, [hashtable]$Vars)
    if (Test-Path $EnvFile) {
        Write-Host "==> $EnvFile exists - leaving it alone"
        return
    }
    Write-Host "==> writing $EnvFile (template)"
    $body = @()
    $body += "# NethraOps agent configuration."
    $body += "# Edit this file then ``Restart-Service ${ServiceName}``."
    $body += ""
    foreach ($key in $Vars.Keys) {
        $body += ("{0}={1}" -f $key, $Vars[$key])
    }
    $dir = Split-Path -Parent $EnvFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -Path $EnvFile -Value $body -Encoding ASCII
}

function Install-Service {
    param(
        [string]$VenvPath
    )
    $svcEntry = Join-Path $VenvPath "Scripts\nethraops-agent-service.exe"
    if (-not (Test-Path $svcEntry)) {
        throw "Service entry not found at $svcEntry. Did pip install succeed?"
    }
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "==> stopping existing service for upgrade"
        if ($existing.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }
        & $svcEntry remove | Out-Null
    }
    Write-Host "==> registering ${ServiceName}"
    & $svcEntry --startup auto install
    if ($LASTEXITCODE -ne 0) { throw "service install failed" }

    # Recovery: restart on each of first 3 failures (60s backoff).
    & sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null

    & sc.exe description $ServiceName "$DisplayName - NethraOps agent" | Out-Null
}

# -- main -----------------------------------------------------------------

Assert-Admin

$venvDir = Join-Path $InstallRoot "venv"
$envFile = Join-Path $DataRoot   "agent.env"
$bufferPath = Join-Path $DataRoot "buffer.sqlite"
$statePath  = Join-Path $DataRoot "state.json"

if (-not (Test-Path $InstallRoot)) { New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null }
if (-not (Test-Path $DataRoot))    { New-Item -ItemType Directory -Force -Path $DataRoot    | Out-Null }

# ACL: keep DataRoot writable only by SYSTEM + Administrators (the
# service runs as LocalSystem by default).
$acl = Get-Acl $DataRoot
$acl.SetAccessRuleProtection($true, $false)
$rules = @(
    New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
)
foreach ($r in $rules) { $acl.AddAccessRule($r) }
Set-Acl -Path $DataRoot -AclObject $acl

if (-not $DeviceSlug) { $DeviceSlug = Get-DefaultDeviceSlug }
if (-not $DeviceName) { $DeviceName = $env:COMPUTERNAME }

# Resolve the source dir (the `agent/` directory containing
# pyproject.toml). The script ships at packaging/windows/, so the
# source is two parents up.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceDir = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path

# Phase 1D: prefer the bundled embeddable Python if the Phase 1D
# bootstrapper laid one down at <InstallRoot>\python\. Falls back to
# whatever -PythonPath resolves to (default "python" - i.e. PATH).
# This is a no-op for Phase 1B MSI-only installs since the directory
# does not exist there.
$bundledPython = Join-Path $InstallRoot 'python\python.exe'
if ($PythonPath -eq 'python' -and (Test-Path $bundledPython)) {
    Write-Host "==> using bundled embeddable Python at $bundledPython"
    $PythonPath = $bundledPython
}

New-VenvIfMissing -VenvPath $venvDir -Python $PythonPath
Install-AgentPackage -VenvPath $venvDir -SourceDir $SourceDir

Write-EnvFileIfMissing -EnvFile $envFile -Vars @{
    "NETHRAOPS_BACKEND_URL"            = $BackendUrl
    "NETHRAOPS_ENROLMENT_TOKEN"        = $EnrolmentToken
    "NETHRAOPS_AGENT_TOKEN"            = $AgentToken
    "NETHRAOPS_DEVICE_SLUG"            = $DeviceSlug
    "NETHRAOPS_DEVICE_NAME"            = $DeviceName
    "NETHRAOPS_DEVICE_TYPE"            = "windows"
    "NETHRAOPS_BUFFER_PATH"            = $bufferPath
    "NETHRAOPS_STATE_PATH"             = $statePath
    "NETHRAOPS_COLLECT_INTERVAL_SECONDS" = "15"
    "NETHRAOPS_FLUSH_INTERVAL_SECONDS"   = "15"
    "NETHRAOPS_FLUSH_BATCH_SIZE"         = "200"
    "NETHRAOPS_MAX_BUFFER_FRAMES"        = "10000"
    "NETHRAOPS_LOG_LEVEL"                = "INFO"
    "NETHRAOPS_LOG_FORMAT"               = "json"
}

Install-Service -VenvPath $venvDir

if (-not $SkipServiceStart) {
    Write-Host "==> starting ${ServiceName}"
    Start-Service -Name $ServiceName
    Start-Sleep -Seconds 1
    $svc = Get-Service -Name $ServiceName
    Write-Host "==> service status: $($svc.Status)"
}

Write-Host ""
Write-Host "==> NethraOps agent installed."
Write-Host "    Service:  $ServiceName"
Write-Host "    Config:   $envFile"
Write-Host "    Buffer:   $bufferPath"
Write-Host "    State:    $statePath"
Write-Host "    Logs:     Get-WinEvent -LogName Application -ProviderName 'Python Service Manager'"
Write-Host ""
