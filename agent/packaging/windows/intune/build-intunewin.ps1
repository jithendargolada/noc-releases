<#
.SYNOPSIS
    Wrap the NethraOps Agent MSI into a .intunewin package using
    the Microsoft IntuneWinAppUtil.exe tool.

.DESCRIPTION
    IntuneWinAppUtil.exe (a.k.a. the "Microsoft Win32 Content Prep Tool")
    is required - it is Windows-only and Microsoft-distributed; this
    script does not download it. Get it from
    https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool.

    The tool packages a setup folder (containing the MSI + install.cmd +
    uninstall.cmd) into a single encrypted .intunewin blob that Intune
    can deploy. The install / uninstall commands and detection rule are
    configured in the Intune admin centre, NOT in the .intunewin itself.

.PARAMETER MsiPath
    Path to the NethraOpsAgent-<version>.msi to package. Defaults
    to the newest MSI under ..\msi\dist\.

.PARAMETER OutputDir
    Where to write the .intunewin. Defaults to a dist\ subdirectory
    beside this script.

.PARAMETER SetupFile
    The "primary" file IntuneWinAppUtil.exe records as the installer.
    Defaults to install.cmd (which msiexec-shells the MSI with the
    operator-supplied CLAIM_TOKEN + PLATFORM_URL).

.EXAMPLE
    PS> .\build-intunewin.ps1
    PS> .\build-intunewin.ps1 -MsiPath ..\msi\dist\NethraOpsAgent-0.1.0.msi
#>

[CmdletBinding()]
param(
    [string] $MsiPath,
    [string] $OutputDir,
    [string] $SetupFile = 'install.cmd',
    [string] $ToolPath = 'IntuneWinAppUtil.exe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$msiDir = (Resolve-Path (Join-Path $here '..\msi\dist')).Path
if (-not $MsiPath) {
    $candidate = Get-ChildItem -Path $msiDir -Filter 'NethraOpsAgent-*.msi' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        Write-Error "No MSI found in $msiDir. Run msi\build.ps1 first."
        exit 1
    }
    $MsiPath = $candidate.FullName
}
if (-not $OutputDir) { $OutputDir = Join-Path $here 'dist' }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

$tool = Get-Command $ToolPath -ErrorAction SilentlyContinue
if (-not $tool) {
    Write-Error "IntuneWinAppUtil.exe not found on PATH. Download from https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool"
    exit 1
}

# Stage a setup folder: the MSI + the install / uninstall .cmd scripts.
$staging = Join-Path $env:TEMP "nethraops-intune-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $staging | Out-Null
try {
    Copy-Item $MsiPath (Join-Path $staging 'NethraOpsAgent.msi')
    Copy-Item (Join-Path $here '..\msi\scripts\install.cmd')   $staging
    Copy-Item (Join-Path $here '..\msi\scripts\uninstall.cmd') $staging
    Copy-Item (Join-Path $here '..\msi\scripts\upgrade.cmd')   $staging
    Copy-Item (Join-Path $here '..\msi\scripts\repair.cmd')    $staging
    Copy-Item (Join-Path $here '..\msi\scripts\detection.ps1') $staging

    Write-Host "[nethraops-intune] staging  : $staging"
    Write-Host "[nethraops-intune] setupfile: $SetupFile"
    Write-Host "[nethraops-intune] output   : $OutputDir"

    & $tool.Source -c $staging -s $SetupFile -o $OutputDir -q
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $result = Get-ChildItem -Path $OutputDir -Filter '*.intunewin' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $result) {
        Write-Error 'IntuneWinAppUtil.exe completed but no .intunewin produced.'
        exit 1
    }

    # Rename to a stable, version-bearing filename if we can find it.
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($MsiPath)
    $final = Join-Path $OutputDir "$stem.intunewin"
    if ($result.FullName -ne $final) {
        Move-Item -Force $result.FullName $final
    }
    Write-Host "[nethraops-intune] OK -> $final"
} finally {
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
}
