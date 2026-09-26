@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
title Push honghuixiezuoban to GitHub

echo ============================================================
echo   Push Honghui Board to GitHub
echo   Repo: honghuixiezuoban
echo ============================================================
echo.

set http_proxy=
set https_proxy=
set HTTP_PROXY=
set HTTPS_PROXY=
set ALL_PROXY=
set all_proxy=

git config --global http.schannelCheckRevoke false
REM Fail fast instead of hanging when the network is blocked.
git config --global http.lowSpeedLimit 1000
git config --global http.lowSpeedTime 15

echo [1/6] Repository status
git log --oneline --decorate -8
echo.

echo [2/6] Detecting correct remote URL
REM Fail fast when the network is blocked, instead of hanging.
set GIT_TERMINAL_PROMPT=0
set GIT_HTTP_TIMEOUT=15
set GIT_HTTP_LOW_SPEED_LIMIT=1000
set GIT_HTTP_LOW_SPEED_TIME=15
set "URL_A=https://github.com/qywccc/honghuixiezuoban.git"
set "URL_B=https://github.com/kyouccc/honghuixiezuoban.git"
set "GOODURL="

git remote set-url origin %URL_A%
git ls-remote origin >nul 2>nul
if not errorlevel 1 goto OK_A

echo       qywccc not reachable, trying kyouccc ...
git remote set-url origin %URL_B%
git ls-remote origin >nul 2>nul
if not errorlevel 1 goto OK_B

echo.
echo       [FAIL] Neither URL is reachable.
echo.
echo       1. Open your repo page in a browser and look at the address bar:
echo          https://github.com/^<YOUR-USERNAME^>/honghuixiezuoban
echo       2. Run this with your real username, then re-run this script:
echo          git remote set-url origin https://github.com/YOURNAME/honghuixiezuoban.git
echo       3. If the URL is correct but still fails, your network blocks GitHub.
echo          Turn on your VPN / proxy software and retry.
echo.
pause
exit /b 1

:OK_A
set "GOODURL=%URL_A%"
echo       [OK] %URL_A%
goto SECURITY

:OK_B
set "GOODURL=%URL_B%"
echo       [OK] %URL_B%
goto SECURITY

:SECURITY
echo.
echo [3/6] Security checks
git ls-files | findstr /X "build-profile.json5" >nul 2>nul
if not errorlevel 1 (
    echo       [DANGER] build-profile.json5 is tracked and contains plain-text signing passwords.
    echo                Run:  git rm --cached build-profile.json5
    pause
    exit /b 1
)
git ls-files | findstr /R /I "\.p12$ \.p7b$ \.cer$ \.keystore$ \.jks$" >nul 2>nul
if not errorlevel 1 (
    echo       [DANGER] Certificate files are tracked. Do NOT push.
    git ls-files | findstr /R /I "\.p12$ \.p7b$ \.cer$"
    pause
    exit /b 1
)
git log -p --all > "%TEMP%\_histscan.txt" 2>nul
findstr /R /C:"storePassword=[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]" "%TEMP%\_histscan.txt" >nul 2>nul
if not errorlevel 1 (
    echo       [DANGER] A real password was found in git history.
    echo                Deleting the file is not enough - you must rewrite history or recreate the repo.
    del "%TEMP%\_histscan.txt" >nul 2>nul
    pause
    exit /b 1
)
del "%TEMP%\_histscan.txt" >nul 2>nul
echo       [PASS] no signing config tracked / no certificates / no real password in history
echo.

echo [4/6] Pushing main branch
REM Restore interactive auth so Git Credential Manager can open the browser.
set GIT_TERMINAL_PROMPT=
set GIT_HTTP_TIMEOUT=
set GIT_HTTP_LOW_SPEED_LIMIT=
set GIT_HTTP_LOW_SPEED_TIME=
echo.
echo       A browser window may pop up. Just log in to GitHub and authorize.
echo.
git push -u origin main
if errorlevel 1 goto FAIL

echo.
echo [5/6] Pushing tag v2.7.8-appstore
git push origin --tags
if errorlevel 1 goto FAIL

echo.
echo [6/6] DONE
echo.
echo ============================================================
echo   PUSH SUCCEEDED
echo   Open: %GOODURL:.git=%
echo ============================================================
pause
exit /b 0

:FAIL
echo.
echo ============================================================
echo   PUSH FAILED - find your error below
echo.
echo   [asks for username / password]
echo     - Username: your GitHub username
echo     - Password: must be a Personal Access Token, NOT your login password
echo     - Create one: GitHub - Settings - Developer settings
echo       - Personal access tokens - Tokens classic - Generate new token
echo       - check the "repo" scope, then copy the ghp_... string
echo     - Easier: git config --global credential.helper manager
echo       then a browser window handles the login for you
echo.
echo   [CONNECT tunnel failed / 502 / Could not connect]
echo     - Proxy or network issue. Turn on your VPN and retry.
echo.
echo   [CRYPT_E_REVOCATION_OFFLINE]
echo     - Run: git config --global http.sslBackend openssl
echo.
echo   [repository not found / 404]
echo     - Wrong username in the remote URL. Check your browser address bar, then:
echo       git remote set-url origin https://github.com/USERNAME/honghuixiezuoban.git
echo.
echo   [rejected / fetch first]
echo     - Remote already has commits. Run: git pull --rebase origin main
echo ============================================================
pause
exit /b 1
