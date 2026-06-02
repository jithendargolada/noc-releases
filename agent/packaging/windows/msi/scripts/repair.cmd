@echo off
REM NethraOps Agent - repair (reinstall all files + re-register
REM the service from the cached MSI). Useful when an operator suspects a
REM corrupted venv or a missing service entry.
REM
REM /fa = repair All files. Logs to %TEMP%\nethraops-repair.log.

setlocal EnableExtensions EnableDelayedExpansion

set "UPGRADE_CODE_REVERSED=A503C516-6EAE-AFD4-CB9A-E68A65010019"
set "PRODUCT_CODE="
for /f "tokens=*" %%K in ('reg query "HKLM\SOFTWARE\Classes\Installer\UpgradeCodes\%UPGRADE_CODE_REVERSED%" 2^>nul') do (
    for /f "tokens=1" %%V in ("%%K") do (
        set "PRODUCT_CODE=%%V"
    )
)

if "%PRODUCT_CODE%"=="" (
    echo NethraOps Agent does not appear to be installed - nothing to repair. 1>&2
    exit /b 1
)

set "LOG=%TEMP%\nethraops-repair.log"
echo [nethraops-repair] product=%PRODUCT_CODE%
echo [nethraops-repair] log=%LOG%

msiexec /fa "%PRODUCT_CODE%" /qn /l*v "%LOG%"
set RC=%ERRORLEVEL%

if "%RC%"=="0" ( echo [nethraops-repair] OK & exit /b 0 )
echo [nethraops-repair] FAILED with msiexec exit code %RC%. See %LOG%. 1>&2
exit /b %RC%
