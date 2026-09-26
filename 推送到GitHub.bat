@echo off
REM ===================================================================
REM  Push Honghui Board to GitHub
REM  Repo: https://github.com/kyouccc/honghuixiezuoban
REM
REM  This file is intentionally 100% ASCII with CRLF line endings.
REM  Reason: cmd.exe parses .bat files with the system ANSI codepage
REM  (GBK on Chinese Windows) and ignores chcp. Non-ASCII bytes in a
REM  .bat cause mojibake and half-lines being executed as commands.
REM ===================================================================
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title Push honghuixiezuoban to GitHub

echo ============================================================
echo   Push Honghui Board to GitHub
echo   Repo: honghuixiezuoban
echo ============================================================
echo.

REM Work around local / corporate proxies that block github.com.
set "http_proxy="
set "https_proxy="
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "ALL_PROXY="
set "all_proxy="

REM CRYPT_E_REVOCATION_OFFLINE workaround (offline CRL servers on Windows).
git config --global http.schannelCheckRevoke false

echo [1/4] Repository status
git log --oneline --decorate -6
echo.

echo [2/4] Security checks
git ls-files | findstr /X "build-profile.json5" >nul 2>nul
if not errorlevel 1 (
    echo       [DANGER] build-profile.json5 is tracked. It contains plain-text signing passwords.
    echo                Fix:  git rm --cached build-profile.json5
    echo.
    pause
    exit /b 1
)
git ls-files | findstr /R /I "\.p12$ \.p7b$ \.cer$ \.keystore$ \.jks$" >nul 2>nul
if not errorlevel 1 (
    echo       [DANGER] Certificate files are tracked. Do NOT push.
    git ls-files | findstr /R /I "\.p12$ \.p7b$ \.cer$"
    echo.
    pause
    exit /b 1
)
echo       [PASS] signing config not tracked, no certificates in the repo
echo.

echo [3/4] Pushing main branch
echo.
echo   +-------------------------------------------------------------+
echo   ^| A BROWSER WINDOW WILL OPEN. Log in to GitHub and authorize. ^|
echo   ^|                                                             ^|
echo   ^| If NO browser opens and this window asks for a password:    ^|
echo   ^|   Username: kyouccc                                         ^|
echo   ^|   Password: a Personal Access Token starting with ghp_      ^|
echo   ^|             NOT your GitHub login password - that fails.    ^|
echo   ^|   See the TOKEN guide printed below if the push fails.      ^|
echo   +-------------------------------------------------------------+
echo.
git push -u origin main
if errorlevel 1 goto FAIL

echo.
echo [4/4] Pushing tag v2.7.8-appstore
git push origin --tags
if errorlevel 1 goto FAIL

echo.
echo ============================================================
echo   PUSH SUCCEEDED
echo   Open: https://github.com/kyouccc/honghuixiezuoban
echo ============================================================
pause
exit /b 0

:FAIL
echo.
echo ============================================================
echo   PUSH FAILED. Find your error below.
echo.
echo   --- Most likely: authentication ----------------------------
echo   "Password authentication is not supported"
echo   "Invalid username or token"
echo   "Cannot prompt because user interactivity has been disabled"
echo.
echo   GitHub does NOT accept your login password. You need a token.
echo   A more reliable route is to run the command manually in Git Bash,
echo   where the browser login tends to work:
echo.
echo       cd /d/honghuixiezuoban
echo       git push -u origin main
echo.
echo   Create a Personal Access Token (30 seconds):
echo     1. Open https://github.com/settings/tokens
echo     2. Generate new token - Tokens classic
echo     3. Note: push-honghui    Expiration: 90 days
echo     4. Tick the "repo" checkbox
echo     5. Generate, then COPY the ghp_... string right away
echo     6. Run:  git push -u origin main
echo        Username: kyouccc
echo        Password: paste the ghp_... token
echo.
echo   --- Network -------------------------------------------------
echo   "Could not resolve host" / "Could not connect" / "timed out"
echo     GitHub is unreachable. Turn on your VPN / proxy and retry.
echo   "CONNECT tunnel failed" / "502"
echo     A proxy is intercepting. Close it, or bypass github.com.
echo.
echo   --- Other ---------------------------------------------------
echo   "repository not found" / "404"
echo     Wrong username in the URL. Check your browser address bar, then:
echo     git remote set-url origin https://github.com/USERNAME/honghuixiezuoban.git
echo   "rejected" / "fetch first"
echo     Remote already has commits. Run: git pull --rebase origin main
echo ============================================================
pause
exit /b 1
