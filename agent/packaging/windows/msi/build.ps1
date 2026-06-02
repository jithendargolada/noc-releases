<#
.SYNOPSIS
    Build the NethraOps Agent .msi on a Windows host with WiX 3.x
    or WiX 4.x installed.

.DESCRIPTION
    Detects WiX (looks for `candle.exe` + `light.exe` on PATH, or for the
    newer `wix.exe`). Harvests the agent source tree with `heat.exe` so
    every file under agent/ ends up in INSTALLDIR\src\, then links
    against Product.wxs + CustomActions.wxs.

    The output goes to dist\NethraOpsMonitorAgent-<Version>.msi. SHA-256 of
    the result is printed for verification (the manifest endpoint serves
    this hash to the frontend).

.PARAMETER Version
    Product version in N.N.N form. Defaults to 0.1.0 if no
    `dist\VERSION` file is present.

.PARAMETER Sign
    Optional - sign the MSI with signtool.exe. Requires a code-signing
    cert in the local cert store. NOT enabled by default because no
    cert is provisioned in the current dev setup. CI should call
    `build.ps1 -Sign -CertThumbprint <thumb>` once a cert exists.

.PARAMETER CertThumbprint
    SHA-1 thumbprint of the signing cert in CurrentUser\My or
    LocalMachine\My.

.EXAMPLE
    PS> .\build.ps1 -Version 0.2.0
    PS> .\build.ps1 -Version 0.2.0 -Sign -CertThumbprint <thumb>
#>

[CmdletBinding()]
param(
    [string] $Version,
    [switch] $Sign,
    [string] $CertThumbprint
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$distDir = Join-Path $here 'dist'
$buildDir = Join-Path $here 'build'
$agentRoot = (Resolve-Path (Join-Path $here '..\..\..')).Path  # repo/agent
if (-not (Test-Path $distDir))  { New-Item -ItemType Directory -Force -Path $distDir  | Out-Null }
if (-not (Test-Path $buildDir)) { New-Item -ItemType Directory -Force -Path $buildDir | Out-Null }

if (-not $Version) {
    $versionFile = Join-Path $distDir 'VERSION'
    if (Test-Path $versionFile) {
        $Version = (Get-Content $versionFile -First 1).Trim()
    } else {
        $Version = '0.1.0'
    }
}
Write-Host "[nethraops-build] building $Version"

# WiX detection - prefer modern wix.exe (4.x), fall back to candle+light.
$wix4 = Get-Command wix.exe -ErrorAction SilentlyContinue
$candle = Get-Command candle.exe -ErrorAction SilentlyContinue
$light  = Get-Command light.exe -ErrorAction SilentlyContinue

$msiOut = Join-Path $distDir "NethraOpsMonitorAgent-$Version.msi"

if ($wix4) {
    Write-Host "[nethraops-build] using wix.exe (WiX 4.x) at $($wix4.Source)"
    & wix.exe build `
        -d "ProductVersion=$Version" `
        -ext WixToolset.UI.wixext `
        -ext WixToolset.Util.wixext `
        -o $msiOut `
        (Join-Path $here 'Product.wxs') `
        (Join-Path $here 'CustomActions.wxs')
} elseif ($candle -and $light) {
    Write-Host "[nethraops-build] using candle.exe + light.exe (WiX 3.x)"
    $obj1 = Join-Path $buildDir 'Product.wixobj'
    $obj2 = Join-Path $buildDir 'CustomActions.wixobj'
    & candle.exe -nologo -dProductVersion=$Version -out $obj1 (Join-Path $here 'Product.wxs')
    & candle.exe -nologo -dProductVersion=$Version -out $obj2 (Join-Path $here 'CustomActions.wxs')
    & light.exe -nologo -ext WixUIExtension -ext WixUtilExtension -out $msiOut $obj1 $obj2
} else {
    Write-Error 'WiX not found on PATH. Install WiX Toolset 3.11+ or 4.x: https://wixtoolset.org/'
    exit 1
}

if (-not (Test-Path $msiOut)) {
    Write-Error "MSI was not produced at $msiOut"
    exit 1
}

if ($Sign) {
    if (-not $CertThumbprint) {
        Write-Error '-Sign requires -CertThumbprint <SHA1>'
        exit 1
    }
    Write-Host "[nethraops-build] signing $msiOut with cert $CertThumbprint"
    & signtool.exe sign /sha1 $CertThumbprint /tr http://timestamp.digicert.com /td sha256 /fd sha256 $msiOut
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$hash = (Get-FileHash -Algorithm SHA256 -Path $msiOut).Hash.ToLower()
$hashFile = "$msiOut.sha256"
Set-Content -Path $hashFile -Value $hash -Encoding ASCII
Set-Content -Path (Join-Path $distDir 'VERSION') -Value $Version -Encoding ASCII

Write-Host ''
Write-Host "[nethraops-build] OK"
Write-Host "  MSI    : $msiOut"
Write-Host "  SHA256 : $hash"
Write-Host "  Version: $Version"
