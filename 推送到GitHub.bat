@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo ============================================================
echo   推送鸿绘协作板到 GitHub
echo   仓库: honghuixiezuoban
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

echo [1/6] 当前仓库状态
git log --oneline --decorate -8
echo.

echo [2/6] 自动校验远程仓库地址
echo       （你的仓库 URL 里可能是 qywccc 或 kyouccc，脚本会自己试出来）
set "URL_A=https://github.com/qywccc/honghuixiezuoban.git"
set "URL_B=https://github.com/kyouccc/honghuixiezuoban.git"
set "GOODURL="

git remote set-url origin %URL_A%
git ls-remote origin >nul 2>nul
if not errorlevel 1 (
    set "GOODURL=%URL_A%"
    echo       [OK] 地址可用: !GOODURL!
    goto REMOTE_DONE
)

echo       第一个地址不通，尝试 kyouccc ...
git remote set-url origin %URL_B%
git ls-remote origin >nul 2>nul
if not errorlevel 1 (
    set "GOODURL=%URL_B%"
    echo       [OK] 地址可用: !GOODURL!
    goto REMOTE_DONE
)

echo.
echo       [失败] 两个地址都无法访问。请按以下步骤处理：
echo.
echo       1) 在浏览器打开你的 GitHub 仓库页面，看地址栏：
echo          地址栏形如  https://github.com/【你的用户名】/honghuixiezuoban
echo       2) 把【你的用户名】填到下面这条命令里执行，然后重新运行本脚本：
echo.
echo          git remote set-url origin https://github.com/你的用户名/honghuixiezuoban.git
echo.
echo       3) 若地址没错但仍不通，说明是网络问题 —— 开启代理软件（VPN）后重试。
echo.
pause
exit /b 1

:REMOTE_DONE
echo.

echo [3/6] 安全检查
git ls-files | findstr /X "build-profile.json5" >nul 2>nul
if %errorlevel%==0 (
    echo       [危险] build-profile.json5 被跟踪！其中含明文签名密码，绝不能推送。
    echo              处理: git rm --cached build-profile.json5
    pause
    exit /b 1
)
git ls-files | findstr /R /I "\.p12$ \.p7b$ \.cer$ \.keystore$ \.jks$" >nul 2>nul
if %errorlevel%==0 (
    echo       [危险] 检测到证书文件被跟踪，绝不能推送。
    git ls-files | findstr /R /I "\.p12$ \.p7b$ \.cer$"
    pause
    exit /b 1
)
git log -p --all > "%TEMP%\_histscan.txt" 2>nul
findstr /R /C:"storePassword=[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]" "%TEMP%\_histscan.txt" >nul 2>nul
if %errorlevel%==0 (
    echo       [危险] git 历史中发现疑似真实密码！只删文件没用，需重写历史或删库重建。
    del "%TEMP%\_histscan.txt" >nul 2>nul
    pause
    exit /b 1
)
del "%TEMP%\_histscan.txt" >nul 2>nul
echo       [通过] 签名配置未跟踪 / 无证书入库 / 历史无真实密码
echo.

echo [4/6] 推送 main 分支（8 个提交）
echo.
echo   ┌─────────────────────────────────────────────────────┐
echo   │ 若弹出浏览器窗口 → 登录你的 GitHub 账号并授权即可   │
echo   │ （已配置 Git Credential Manager，无需 Personal Token）│
echo   └─────────────────────────────────────────────────────┘
echo.
git push -u origin main
if errorlevel 1 goto FAIL

echo.
echo [5/6] 推送标签 v2.7.8-appstore
git push origin --tags
if errorlevel 1 goto FAIL

echo.
echo [6/6] 完成
echo.
echo ============================================================
echo   推送成功！
echo   打开查看: !GOODURL:.git=!
echo ============================================================
pause
exit /b 0

:FAIL
echo.
echo ============================================================
echo   推送失败。按提示的数字对号入座：
echo.
echo   【弹窗要求输入用户名密码】
echo     - 用户名填你的 GitHub 用户名
echo     - 密码栏【必须填 Personal Access Token】，
echo       GitHub 不接受登录密码，也不是 QQ 邮箱密码
echo     - 生成: GitHub -^> Settings -^> Developer settings
echo             -^> Personal access tokens -^> Tokens (classic)
echo             -^> Generate new token，勾选 repo 权限，复制得到的 ghp_ 开头的串
echo     - 更简单: 先执行 git config --global credential.helper manager
echo       推送时会自动弹浏览器登录，无需 Token
echo.
echo   【CONNECT tunnel failed / 502 / Could not connect】
echo     - 存在代理或网络受限。脚本已尝试清除代理，
echo       若仍失败请开启代理软件（VPN）后重试。
echo.
echo   【CRYPT_E_REVOCATION_OFFLINE】
echo     - 执行: git config --global http.sslBackend openssl
echo.
echo   【repository not found / 404】
echo     - 远程地址里的用户名不对。到浏览器看你的仓库地址栏，
echo       然后: git remote set-url origin https://github.com/用户名/honghuixiezuoban.git
echo.
echo   【rejected / fetch first】
echo     - 远程已有内容。执行: git pull --rebase origin main 后再推
echo ============================================================
pause
exit /b 1
