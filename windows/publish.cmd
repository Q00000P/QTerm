@echo off
rem QTerm release build: QTerm.exe (self-contained single-file) + QEditor.exe из соседнего
rem репо QEditor (..\QEditor\windows\publish, свой publish.cmd; путь — QEDITOR_EXE).
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

if "%QEDITOR_EXE%"=="" set QEDITOR_EXE=..\QEditor\windows\publish\QEditor.exe
if exist "%QEDITOR_EXE%" (
  copy /y "%QEDITOR_EXE%" publish\ >nul
  echo QEditor.exe: %QEDITOR_EXE%
) else (
  echo !!! QEditor.exe не найден: %QEDITOR_EXE% — редактора в сборке не будет.
  echo !!! git clone https://github.com/Q00000P/QEditor ..\QEditor ^&^& ..\QEditor\windows\publish.cmd
)

del /q publish\*.pdb >nul 2>&1
powershell -NoProfile -Command "Compress-Archive -Path publish\* -DestinationPath QTerm-win-portable.zip -Force"

echo.
echo Done: publish\QTerm.exe (+ QEditor.exe, если нашёлся; QTerm-win-portable.zip)
endlocal
