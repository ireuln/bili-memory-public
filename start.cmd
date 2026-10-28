@echo off
setlocal
cd /d "%~dp0"
set "LOGDIR=%TEMP%\bili-memory-logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>nul
echo [%date% %time%] start begin: %~dp0>>"%LOGDIR%\start.log"

if not exist "config.json" (
  echo [%date% %time%] config.json missing; running setup>>"%LOGDIR%\start.log"
  echo.
  echo First run: setup will ask for a data folder and open Edge for login.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
  if errorlevel 1 (
    echo [%date% %time%] setup failed; exit>>"%LOGDIR%\start.log"
    echo.
    echo Setup failed. Press any key to close.
    pause >nul
    exit /b 1
  )
)

if not exist "config.json" (
  echo [%date% %time%] config.json still missing; exit>>"%LOGDIR%\start.log"
  echo config.json is still missing; run setup.ps1 manually.
  pause >nul
  exit /b 1
)

echo [%date% %time%] launching tray.ps1>>"%LOGDIR%\start.log"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tray.ps1"
exit /b 0
