@echo off
REM ============================================
REM 鸿绘协作板 — 构建与签名脚本
REM 使用方法: build-and-sign.bat [debug|release]
REM ============================================

set BUILD_MODE=%1
if "%BUILD_MODE%"=="" set BUILD_MODE=release

echo === 鸿绘协作板构建 ===
echo 构建模式: %BUILD_MODE%

REM 1. 使用hvigor构建hap包
echo [1/4] 构建hap包...
hvigorw assembleHap -p buildMode=%BUILD_MODE%
if %ERRORLEVEL% NEQ 0 (
    echo 构建失败!
    exit /b 1
)

REM 2. 检查包体大小
echo [2/4] 检查包体大小...
for %%F in (entry\build\default\outputs\default\*.hap) do (
    set HAP_SIZE=%%~zF
    set HAP_PATH=%%F
)
set /a HAP_SIZE_MB=%HAP_SIZE% / 1048576
echo hap包大小: %HAP_SIZE_MB% MB
if %HAP_SIZE_MB% GTR 10 (
    echo ⚠️ 警告: 包体超过10MB限制!
)

REM 3. 签名 (使用DevEco Studio生成的.p12和.cer)
echo [3/4] 签名...
hvigorw packageSign -p buildMode=%BUILD_MODE% ^
    -p storeFile=harmonycanvas.p12 ^
    -p storePassword=your_password ^
    -p keyAlias=harmonycanvas ^
    -p keyPassword=your_password ^
    -p profile=harmonycanvas_release.p7b
if %ERRORLEVEL% NEQ 0 (
    echo 签名失败! 请检查签名配置
    exit /b 1
)

echo [4/4] 构建完成!
echo 输出路径: entry\build\default\outputs\default\
echo hap文件已就绪，可提交至华为应用市场审核
echo https://developer.huawei.com/consumer/cn/service/josp/agc/index.html
