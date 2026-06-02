# NethraOps Agent - MSI launcher shim.
#
# Invoked by the deferred custom action InstallAgentDeferred. Parses the
# CustomActionData blob (key=value pairs separated by '|') and hands off
# to the existing Phase 1A Install-NethraOpsAgent.ps1.
#
# The MSI's job is staging + Windows Installer book-keeping; the actual
# registration + venv + service work is owned by Install-NethraOpsAgent.ps1
# - this shim is the single seam between them.
#
# ASCII only. PowerShell 5.x mis-decodes em-dashes as closing quotes.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Data
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Parse-Blob {
    param([string]$Blob)
    $result = @{}
    foreach ($pair in $Blob -split '\|') {
        if ($pair -match '^(?<k>[^=]+)=(?<v>.*)$') {
            $result[$Matches['k']] = $Matches['v']
        }
    }
    return $result
}

$parts = Parse-Blob -Blob $Data

$claim       = $parts['CLAIM']
$platformUrl = $parts['URL']
$group       = $parts['GROUP']
$label       = $parts['LABEL']
$python      = if ($parts.ContainsKey('PY') -and $parts['PY']) { $parts['PY'] } else { 'python' }
$installDir  = $parts['INSTALLDIR']
$dataDir     = $parts['DATADIR']

# Phase 1D: if the bootstrapper wrote out an embeddable Python next to
# the install root, prefer it over PATH. The bootstrapper passes
# PYTHON_PATH explicitly so this fallback is only exercised on
# MSI-direct installs whose operator left PYTHON_PATH at the default
# of "python" but still happened to run with the embeddable present
# (e.g. after a bootstrapper-installed agent was downgraded to the
# bare MSI).
$bundledPython = Join-Path $installDir 'python\python.exe'
if ($python -eq 'python' -and (Test-Path $bundledPython)) {
    $python = $bundledPython
}

if (-not $claim) {
    Write-Error 'CLAIM_TOKEN is required (msiexec /i ... CLAIM_TOKEN=...).'
    exit 2
}
if (-not $platformUrl) {
    Write-Error 'PLATFORM_URL is required (msiexec /i ... PLATFORM_URL=https://...).'
    exit 2
}

# Step 1: redeem the claim against the public install endpoint to mint a
# one-shot enrolment token. We use the same endpoint that the curl /
# Invoke-WebRequest one-liner from the wizard hits, but discard the
# rendered script body - we only want the token it embeds. This keeps the
# MSI free of any direct AgentService logic; everything still goes
# through the Phase 1A flow.
$scriptUrl = "$($platformUrl.TrimEnd('/'))/install/windows.ps1?claim=$([uri]::EscapeDataString($claim))"
Write-Host "[nethraops-msi] redeeming claim against $scriptUrl"
try {
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $scriptUrl -ErrorAction Stop
} catch {
    Write-Error "Failed to redeem install claim: $($_.Exception.Message)"
    exit 3
}
if ($resp.StatusCode -ne 200) {
    Write-Error "Install claim rejected: HTTP $($resp.StatusCode) - $($resp.Content)"
    exit 3
}

# Extract the enrolment token + device slug + device name from the
# rendered PowerShell script body. The Phase 1A template substitutes
# NETHRAOPS_ENROLMENT_TOKEN / DeviceSlug / DeviceName literally so a couple
# of regexes are enough.
$body = $resp.Content
$tokenMatch = [regex]::Match($body, "NETHRAOPS_ENROLMENT_TOKEN\s*=\s*'([^']+)'")
$slugMatch  = [regex]::Match($body, "-DeviceSlug\s+'([^']+)'")
$nameMatch  = [regex]::Match($body, "-DeviceName\s+'([^']+)'")

if (-not $tokenMatch.Success) {
    Write-Error 'Could not extract NETHRAOPS_ENROLMENT_TOKEN from rendered install script. Backend version mismatch?'
    exit 4
}

$enrolment = $tokenMatch.Groups[1].Value
$slug = if ($label) { $label } elseif ($slugMatch.Success) { $slugMatch.Groups[1].Value } else { ($env:COMPUTERNAME).ToLowerInvariant() }
$name = if ($label) { $label } elseif ($nameMatch.Success) { $nameMatch.Groups[1].Value } else { $env:COMPUTERNAME }

# Step 2: hand off to the existing installer. It lives next to this
# script in INSTALLDIR\packaging\windows\.
$installer = Join-Path $installDir 'packaging\windows\Install-NethraOpsAgent.ps1'
if (-not (Test-Path $installer)) {
    Write-Error "Install-NethraOpsAgent.ps1 not found at $installer. The MSI is missing the agent payload."
    exit 5
}

Write-Host "[nethraops-msi] handing off to $installer"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
    -BackendUrl $platformUrl `
    -EnrolmentToken $enrolment `
    -DeviceSlug $slug `
    -DeviceName $name `
    -PythonPath $python

if ($LASTEXITCODE -ne 0) {
    Write-Error "Install-NethraOpsAgent.ps1 exited with code $LASTEXITCODE"
    exit $LASTEXITCODE
}

# TODO(phase-1C): phone home with agent.install.succeeded /
# agent.install.failed once the backend exposes a public hook. The
# audit-action constants are already reserved in
# backend/app/api/downloads.py.
Write-Host '[nethraops-msi] install complete.'
exit 0
