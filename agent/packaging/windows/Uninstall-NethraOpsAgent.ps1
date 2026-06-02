<#
.SYNOPSIS
    Uninstalls the NethraOps Windows Service + venv.

.PARAMETER Purge
    Also remove C:\ProgramData\NethraOpsAgent (config, buffer, state).
    Without this, those files are preserved so a re-install picks up
    the same identity.

.EXAMPLE
    PS> .\Uninstall-NethraOpsAgent.ps1
    PS> .\Uninstall-NethraOpsAgent.ps1 -Purge
#>

[CmdletBinding()]
param(
    [switch] $Purge,
    [string] $InstallRoot = "C:\Program Files\NethraOpsAgent",
    [string] $DataRoot    = "C:\ProgramData\NethraOpsAgent"
)

$ErrorActionPreference = "Stop"
$ServiceName = "NethraOpsAgent"

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Uninstall-NethraOpsAgent.ps1 must be run as Administrator."
    }
}

Assert-Admin

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne 'Stopped') {
        Write-Host "==> stopping $ServiceName"
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    }
    $svcEntry = Join-Path $InstallRoot "venv\Scripts\nethraops-agent-service.exe"
    if (Test-Path $svcEntry) {
        & $svcEntry remove | Out-Null
    } else {
        & sc.exe delete $ServiceName | Out-Null
    }
}

if (Test-Path $InstallRoot) {
    Write-Host "==> removing $InstallRoot"
    Remove-Item -Recurse -Force $InstallRoot
}

if ($Purge -and (Test-Path $DataRoot)) {
    Write-Host "==> --Purge: removing $DataRoot"
    Remove-Item -Recurse -Force $DataRoot
}

Write-Host "==> done."
