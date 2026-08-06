@echo off
setlocal

set "PROJECT_DIR=%~dp0"
set "APK_RELEASE=%PROJECT_DIR%app\build\app\outputs\flutter-apk\app-release.apk"
set "APK_DEBUG=%PROJECT_DIR%app\build\app\outputs\flutter-apk\app-debug.apk"
set "EXTENSION_DIR=%PROJECT_DIR%extension\dist"
set "ZIP_OUT=%PROJECT_DIR%PeerVault_TestingBuild.zip"

echo [1] Checking for Android APK...
set "TARGET_APK="

if exist "%APK_RELEASE%" (
    echo [INFO] Found Release APK at app-release.apk
    set "TARGET_APK=%APK_RELEASE%"
) else if exist "%APK_DEBUG%" (
    echo [INFO] Found Debug APK at app-debug.apk
    set "TARGET_APK=%APK_DEBUG%"
) else (
    echo [ERROR] Cannot find app-release.apk or app-debug.apk. Please build the Flutter app first.
    pause
    exit /b 1
)

echo [2] Checking for Extension build...
if not exist "%EXTENSION_DIR%" (
    echo [ERROR] Cannot find extension 'dist' folder. Please build the extension first using NPM.
    pause
    exit /b 1
)

echo [3] Preparing staging directory...
set "STAGING_DIR=%PROJECT_DIR%temp_peervault_staging"
if exist "%STAGING_DIR%" rmdir /s /q "%STAGING_DIR%"
mkdir "%STAGING_DIR%"

echo Copied App...
copy "%TARGET_APK%" "%STAGING_DIR%\PeerVault_Android.apk" >nul

echo Copied Extension...
xcopy "%EXTENSION_DIR%" "%STAGING_DIR%\PeerVault_Extension" /E /I /H /Y >nul

echo Copied Testing Guide...
copy "%PROJECT_DIR%Testing_Guide.md" "%STAGING_DIR%\Testing_Guide.md" >nul

echo [4] Zipping the bundle using PowerShell...
if exist "%ZIP_OUT%" del "%ZIP_OUT%"
powershell -NoProfile -Command "Compress-Archive -Path '%STAGING_DIR%\*' -DestinationPath '%ZIP_OUT%' -Force"

echo [5] Cleaning up staging directory...
rmdir /s /q "%STAGING_DIR%"

echo.
echo ========================================================
echo SUCCESS: Finished packaging! 
echo Your zip file is ready at: %ZIP_OUT%
echo ========================================================
pause
