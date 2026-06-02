# NethraOps Agent - MSI uninstall shim.
#
# Invoked by the deferred custom action UninstallAgentDeferred. Stops +
# removes the Windows service and (unless KEEP_CONFIG=1) deletes
# C:\ProgramData\NethraOpsAgent. The MSI itself removes INSTALLDIR.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Data
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$parts = @{}
foreach ($pair in $Data -split '\|') {
    if ($pair -match '^(?<k>[^=]+)=(?<v>.*)$') {
        $parts[$Matches['k']] = $Matches['v']
    }
}

$dataDir    = $parts['DATADIR']
$keepConfig = ($parts['KEEP_CONFIG'] -eq '1')
$installDir = $parts['INSTALLDIR']

$svc = Get-Service -Name 'NethraOpsAgent' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host '[nethraops-msi] stopping NethraOpsAgent service'
    try { Stop-Service -Name 'NethraOpsAgent' -Force -ErrorAction Stop } catch {}

    $svcEntry = Join-Path $installDir 'venv\Scripts\nethraops-agent-service.exe'
    if (Test-Path $svcEntry) {
        & $svcEntry remove | Out-Null
    } else {
        & sc.exe delete NethraOpsAgent | Out-Null
    }
}

if (-not $keepConfig -and $dataDir -and (Test-Path $dataDir)) {
    Write-Host "[nethraops-msi] removing data directory $dataDir"
    Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
} elseif ($keepConfig) {
    Write-Host "[nethraops-msi] KEEP_CONFIG=1, preserving $dataDir"
}

exit 0
