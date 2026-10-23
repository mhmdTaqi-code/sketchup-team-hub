@echo off
chcp 65001 >nul
title Team Hub Server
cd /d "%~dp0server"
if not exist node_modules (
  echo Installing server dependencies...
  call npm install --no-audit --no-fund
)
echo Starting Team Hub server... keep this window open while the team is working.
node --no-warnings=ExperimentalWarning server.js
pause
