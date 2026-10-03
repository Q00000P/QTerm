@echo off
rem QTerm release build: QTerm.exe + QEditor.exe (self-contained single-file each)
rem Assets\ must stay next to QTerm.exe (WebView2 maps that folder), so ship
rem the whole publish\ folder (or QTerm-win-portable.zip).
setlocal
cd /d "%~dp0"
taskkill /im QTerm.exe /f >nul 2>&1
taskkill /im QEditor.exe /f >nul 2>&1
if exist publish rmdir /s /q publish

set FLAGS=-c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o publish

dotnet publish QTermWin.csproj %FLAGS%
if errorlevel 1 exit /b 1
dotnet publish Editor\QEditor.csproj %FLAGS%
if errorlevel 1 exit /b 1

del /q publish\*.pdb >nul 2>&1
powershell -NoProfile -Command "Compress-Archive -Path publish\* -DestinationPath QTerm-win-portable.zip -Force"

echo.
echo Done: publish\QTerm.exe + publish\QEditor.exe (+ QTerm-win-portable.zip)
endlocal
