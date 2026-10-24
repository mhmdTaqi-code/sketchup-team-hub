@echo off
chcp 65001 >nul
title Team Hub Server
cd /d "%~dp0server"
if not exist node_modules (
  echo Installing server dependencies...
  call npm install --no-audit --no-fund
)
echo Starting Team Hub server... keep this window open while the team is working.
:run
node --no-warnings=ExperimentalWarning server.js
echo.
echo The server stopped. Restarting in 3 seconds... (close this window to stop it for good)
timeout /t 3 /nobreak >nul
goto run
