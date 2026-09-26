@echo off
REM Set console to UTF-8 so Chinese commit messages render correctly.
REM Safe here because this .bat is 100% ASCII (cmd parses the file with the ANSI codepage).
chcp 65001 >nul
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
REM Fail fast and do not open a browser during detection.
set GIT_TERMINAL_PROMPT=0
set GCM_INTERACTIVE=never
set GIT_HTTP_TIMEOUT=15
REM Confirmed by live probe: the repo lives under kyouccc.
REM Fallback to qywccc is kept in case the account is renamed later.
set "URL_A=https://github.com/kyouccc/honghuixiezuoban.git"
set "URL_B=https://github.com/qywccc/honghuixiezuoban.git"
set "GOODURL="

call :PROBE A "%URL_A%"
if defined GOODURL goto SECURITY
call :PROBE B "%URL_B%"
if defined GOODURL goto SECURITY

echo.
echo       [FAIL] Neither URL works. See the real errors above.
echo.
echo       HOW TO READ THE ERROR ABOVE:
echo.
echo       * "Repository not found" / "404" / "Authentication failed"
echo         [!] The username in the URL is wrong, OR the repo is private.
echo            Fix: open your repo in a browser, copy the address bar,
echo                 then run:
echo                 git remote set-url origin https://github.com/REAL-USER/honghuixiezuoban.git
echo.
echo       * "Could not resolve host" / "Could not connect" / "timed out"
echo         [!] Network problem. GitHub is unreachable from your machine.
echo            Turn on your VPN / proxy and retry.
echo.
echo       * "CONNECT tunnel failed" / "502"
echo         [!] A proxy is intercepting the connection. Close your proxy
echo            software, or set it to bypass github.com, then retry.
echo.
pause
exit /b 1

:PROBE
REM %1 = label, %2 = url
echo.
echo       Testing %2
git ls-remote %2 > "%TEMP%\_probe.txt" 2>&1
if not errorlevel 1 (
    set "GOODURL=%2"
    echo       [OK] reachable
    del "%TEMP%\_probe.txt" >nul 2>nul
    goto :eof
)
echo       [FAIL] git says:
type "%TEMP%\_probe.txt"
del "%TEMP%\_probe.txt" >nul 2>nul
goto :eof

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
REM ------------------------------------------------------------------
REM Re-enable interactive auth. These were turned OFF for the probe step,
REM and GCM_INTERACTIVE=never was the reason the browser never opened:
REM   "fatal: Cannot prompt because user interactivity has been disabled."
REM Set explicit positive values instead of relying on "unset".
REM ------------------------------------------------------------------
set "GIT_HTTP_TIMEOUT="
set "GIT_HTTP_LOW_SPEED_LIMIT="
set "GIT_HTTP_LOW_SPEED_TIME="
set "GIT_TERMINAL_PROMPT=1"
set "GCM_INTERACTIVE=true"
set "GCM_PROVIDER=github"
git config --global credential.interactive auto

echo.
echo       +------------------------------------------------------+
echo       ^| A BROWSER WINDOW WILL OPEN - just log in and authorize ^|
echo       ^|                                                        ^|
echo       ^| If it does NOT open and you are asked for a password   ^|
echo       ^| in this window, do NOT type your GitHub login password ^|
echo       ^| (it will always fail). Press Ctrl+C and use a token:   ^|
echo       ^| see the TOKEN instructions printed below if push fails.^|
echo       +------------------------------------------------------+
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
