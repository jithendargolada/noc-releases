@echo off
REM NethraOps Agent - silent uninstall wrapper.
REM
REM Usage:
REM   uninstall.cmd                     -> removes everything
REM   uninstall.cmd /KEEP_CONFIG        -> preserves C:\ProgramData\NethraOpsAgent
REM
REM Looks up the product code by name so an admin does not need to know
REM the GUID. Logs to %TEMP%\nethraops-uninstall.log.

setlocal EnableExtensions EnableDelayedExpansion

set "KEEP=0"
if /i "%~1"=="/KEEP_CONFIG" set "KEEP=1"
if /i "%~1"=="-KEEP_CONFIG" set "KEEP=1"

set "LOG=%TEMP%\nethraops-uninstall.log"

REM Resolve the product code via the registry. The UpgradeCode is
REM stable; Windows Installer keeps a reverse-lookup under
REM HKLM\SOFTWARE\Classes\Installer\UpgradeCodes\<reversed-guid>.
set "UPGRADE_CODE_REVERSED=A503C516-6EAE-AFD4-CB9A-E68A65010019"

set "PRODUCT_CODE="
for /f "tokens=*" %%K in ('reg query "HKLM\SOFTWARE\Classes\Installer\UpgradeCodes\%UPGRADE_CODE_REVERSED%" 2^>nul') do (
    for /f "tokens=1" %%V in ("%%K") do (
        set "PRODUCT_CODE=%%V"
    )
)

if "%PRODUCT_CODE%"=="" (
    echo NethraOps Agent does not appear to be installed. 1>&2
    exit /b 1
)

echo [nethraops-uninstall] product=%PRODUCT_CODE%
echo [nethraops-uninstall] log=%LOG%
echo [nethraops-uninstall] keep_config=%KEEP%

msiexec /x "%PRODUCT_CODE%" /qn /l*v "%LOG%" KEEP_CONFIG=%KEEP%
set RC=%ERRORLEVEL%

if "%RC%"=="0" (
    echo [nethraops-uninstall] OK
    exit /b 0
)
echo [nethraops-uninstall] FAILED with msiexec exit code %RC%. See %LOG%. 1>&2
exit /b %RC%
