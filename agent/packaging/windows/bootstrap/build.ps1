<#
.SYNOPSIS
    Build the NethraOps Agent bootstrapper EXE (Phase 1D).

.DESCRIPTION
    Compiles Bundle.wxs + PythonEmbed.wxs into a WiX Burn `.exe`
    bootstrapper that wraps the existing Phase 1B NethraOpsAgent.msi
    plus the Python 3.11 embeddable distribution.

    Prerequisites:
      * WiX Toolset 3.11+ (candle.exe + light.exe) OR WiX 4 (wix.exe).
      * The MSI passed via -MsiPath (defaults to
        ..\msi\dist\NethraOpsAgent-<version>.msi or whichever
        version matches -Version).

    Output: dist\NethraOpsAgentBootstrap-<version>.exe + .sha256
    sidecar. Optional Authenticode signing via -Sign.

.PARAMETER Version
    Product version (N.N.N). Falls back to ..\msi\dist\VERSION.

.PARAMETER MsiPath
    Absolute or relative path to the MSI to wrap. Defaults to the
    latest NethraOpsAgent-<Version>.msi under ..\msi\dist\.

.PARAMETER PythonVersion / PythonZipUrl / PythonZipSha512 / PythonZipSize
    Override the Python embeddable distribution metadata baked into
    PythonEmbed.wxs. Production CI passes the real, current python.org
    values; the defaults in PythonEmbed.wxs are placeholders.

.PARAMETER Sign
    Switch - sign the produced EXE with signtool.exe (requires
    -CertThumbprint).

.PARAMETER CertThumbprint
    SHA-1 thumbprint of the code-signing cert in CurrentUser\My
    or LocalMachine\My.

.EXAMPLE
    PS> .\build.ps1 -Version 0.2.0 `
            -PythonZipSha512 "<128-hex-chars>" `
            -PythonZipSize 10000000
#>

[CmdletBinding()]
param(
    [string] $Version,
    [string] $MsiPath,
    [string] $PythonVersion = '3.11.9',
    [string] $PythonZipUrl  = 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip',
    [string] $PythonZipSha512,
    [string] $PythonZipSize,
    [switch] $Sign,
    [string] $CertThumbprint
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$distDir = Join-Path $here 'dist'
$buildDir = Join-Path $here 'build'
$msiDistDir = (Resolve-Path (Join-Path $here '..\msi\dist')).Path
if (-not (Test-Path $distDir))  { New-Item -ItemType Directory -Force -Path $distDir  | Out-Null }
if (-not (Test-Path $buildDir)) { New-Item -ItemType Directory -Force -Path $buildDir | Out-Null }

if (-not $Version) {
    $versionFile = Join-Path $msiDistDir 'VERSION'
    if (Test-Path $versionFile) {
        $Version = (Get-Content $versionFile -First 1).Trim()
    } else {
        $Version = '0.1.0'
    }
}
Write-Host "[nethraops-bootstrap] building $Version"

if (-not $MsiPath) {
    $candidate = Join-Path $msiDistDir "NethraOpsAgent-$Version.msi"
    if (Test-Path $candidate) {
        $MsiPath = (Resolve-Path $candidate).Path
    } else {
        $stable = Join-Path $msiDistDir 'NethraOpsAgent.msi'
        if (Test-Path $stable) {
            $MsiPath = (Resolve-Path $stable).Path
        } else {
            Write-Error "Could not locate MSI to wrap. Pass -MsiPath or build the MSI first (..\msi\build.ps1)."
            exit 1
        }
    }
}
Write-Host "[nethraops-bootstrap] wrapping $MsiPath"

# Compose the WiX -d defines we need to forward.
$wixDefines = @(
    "ProductVersion=$Version"
    "MsiPath=$MsiPath"
    "PythonVersion=$PythonVersion"
    "PythonZipUrl=$PythonZipUrl"
)
if ($PythonZipSha512) { $wixDefines += "PythonZipSha512=$PythonZipSha512" }
if ($PythonZipSize)   { $wixDefines += "PythonZipSize=$PythonZipSize" }

$wix4 = Get-Command wix.exe -ErrorAction SilentlyContinue
$candle = Get-Command candle.exe -ErrorAction SilentlyContinue
$light  = Get-Command light.exe -ErrorAction SilentlyContinue

$exeOut = Join-Path $distDir "NethraOpsAgentBootstrap-$Version.exe"

if ($wix4) {
    Write-Host "[nethraops-bootstrap] using wix.exe (WiX 4.x)"
    $defineArgs = @()
    foreach ($d in $wixDefines) { $defineArgs += @('-d', $d) }
    & wix.exe build `
        @defineArgs `
        -ext WixToolset.Bal.wixext `
        -ext WixToolset.Util.wixext `
        -o $exeOut `
        (Join-Path $here 'Bundle.wxs') `
        (Join-Path $here 'PythonEmbed.wxs')
} elseif ($candle -and $light) {
    Write-Host "[nethraops-bootstrap] using candle.exe + light.exe (WiX 3.x)"
    $defineArgs = @()
    foreach ($d in $wixDefines) { $defineArgs += "-d$d" }
    $obj1 = Join-Path $buildDir 'Bundle.wixobj'
    $obj2 = Join-Path $buildDir 'PythonEmbed.wixobj'
    & candle.exe -nologo -ext WixBalExtension -ext WixUtilExtension @defineArgs -out $obj1 (Join-Path $here 'Bundle.wxs')
    & candle.exe -nologo -ext WixBalExtension -ext WixUtilExtension @defineArgs -out $obj2 (Join-Path $here 'PythonEmbed.wxs')
    & light.exe -nologo -ext WixBalExtension -ext WixUtilExtension -out $exeOut $obj1 $obj2
} else {
    Write-Error 'WiX not found on PATH. Install WiX Toolset 3.11+ or 4.x: https://wixtoolset.org/'
    exit 1
}

if (-not (Test-Path $exeOut)) {
    Write-Error "Bootstrapper EXE was not produced at $exeOut"
    exit 1
}

if ($Sign) {
    if (-not $CertThumbprint) {
        Write-Error '-Sign requires -CertThumbprint <SHA1>'
        exit 1
    }
    Write-Host "[nethraops-bootstrap] signing $exeOut with cert $CertThumbprint"
    # Burn bundles use insignia.exe to detach + re-attach the engine
    # signature so the embedded MSI signature is preserved. Modern
    # signtool handles this transparently on .exe files - we run it
    # directly and let signtool re-pack.
    & signtool.exe sign /sha1 $CertThumbprint /tr http://timestamp.digicert.com /td sha256 /fd sha256 $exeOut
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$hash = (Get-FileHash -Algorithm SHA256 -Path $exeOut).Hash.ToLower()
Set-Content -Path "$exeOut.sha256" -Value $hash -Encoding ASCII
Set-Content -Path (Join-Path $distDir 'VERSION') -Value $Version -Encoding ASCII

Write-Host ''
Write-Host "[nethraops-bootstrap] OK"
Write-Host "  EXE    : $exeOut"
Write-Host "  SHA256 : $hash"
Write-Host "  Version: $Version"
