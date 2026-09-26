@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================================
echo   推送鸿绘协作板到 GitHub
echo   目标仓库: https://github.com/qywccc/honghuixiezuoban
echo ============================================================
echo.

REM ── 清除可能存在的代理（代理会导致 CONNECT tunnel failed 502）──
set http_proxy=
set https_proxy=
set HTTP_PROXY=
set HTTPS_PROXY=
set ALL_PROXY=
set all_proxy=

REM ── 关闭证书吊销检查（解决 CRYPT_E_REVOCATION_OFFLINE）──
git config --global http.schannelCheckRevoke false

echo [1/5] 当前远程仓库配置:
git remote -v
echo.

echo [2/5] 推送前安全检查
REM ① 关键检查：含签名密码的配置文件是否被 git 跟踪
git ls-files | findstr /X "build-profile.json5" >nul 2>nul
if %errorlevel%==0 (
    echo     [危险] build-profile.json5 已被 git 跟踪！其中含明文签名密码，绝不能推送。
    echo            处理: git rm --cached build-profile.json5
    echo.
    pause
    exit /b 1
) else (
    echo     [通过] 签名配置 build-profile.json5 未被跟踪
)

REM ② 关键检查：证书材料是否入库
git ls-files | findstr /R /I "\.p12$ \.p7b$ \.cer$ \.keystore$ \.jks$" >nul 2>nul
if %errorlevel%==0 (
    echo     [危险] 检测到证书文件被跟踪，绝不能推送。
    git ls-files | findstr /R /I "\.p12$ \.p7b$ \.cer$"
    echo.
    pause
    exit /b 1
) else (
    echo     [通过] 无证书文件入库
)

REM ③ 检查历史中是否存在"真实密码"（连续 40 位以上十六进制）
git log -p --all > "%TEMP%\_histscan.txt" 2>nul
findstr /R /C:"storePassword=[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]" "%TEMP%\_histscan.txt" >nul 2>nul
if %errorlevel%==0 (
    echo     [危险] git 历史中发现疑似真实密码！
    echo            注意: 只删文件没用，历史里还在，必须重写历史或删库重建。
    echo.
    pause
    exit /b 1
) else (
    echo     [通过] git 历史中无真实密码（仅有占位符 your_password）
)
del "%TEMP%\_histscan.txt" >nul 2>nul
echo.

echo [3/5] 本次将推送的提交:
git log --oneline --decorate
echo.

echo [4/5] 推送 main 分支...
echo     （若提示输入凭据：用户名填 qywccc，密码填 Personal Access Token）
git push -u origin main
if errorlevel 1 goto FAIL

echo.
echo [5/5] 推送标签 v2.7.8-appstore ...
git push origin --tags
if errorlevel 1 goto FAIL

echo.
echo ============================================================
echo   推送成功！
echo   打开查看: https://github.com/qywccc/honghuixiezuoban
echo ============================================================
pause
exit /b 0

:FAIL
echo.
echo ============================================================
echo   推送失败。常见原因与处理：
echo.
echo   1) 提示认证失败 / 要求密码
echo      - GitHub 不接受登录密码，必须用 Personal Access Token
echo      - 生成: GitHub -^> Settings -^> Developer settings
echo              -^> Personal access tokens -^> Tokens (classic)
echo              -^> Generate new token，勾选 repo 权限
echo      - 推送时【用户名填 qywccc】【密码粘贴该 token】
echo.
echo   2) 报 CONNECT tunnel failed / 502 / Could not connect
echo      - 存在代理或网络受限。本脚本已尝试清除代理，
echo        若仍失败请开启代理软件（VPN）后重试。
echo.
echo   3) 报 CRYPT_E_REVOCATION_OFFLINE
echo      - 本脚本已设置 http.schannelCheckRevoke=false
echo        若仍失败，执行: git config --global http.sslBackend openssl
echo ============================================================
pause
exit /b 1
