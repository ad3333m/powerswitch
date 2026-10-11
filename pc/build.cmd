@echo off
cd /d "%~dp0"
if not exist dist mkdir dist
if not exist assets\app.ico powershell -NoProfile -ExecutionPolicy Bypass -File ..\tools\make_icons.ps1
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -nologo -target:winexe -codepage:65001 -optimize -out:dist\PowerSwitch.exe -win32icon:assets\app.ico -win32manifest:src\app.manifest -r:System.Windows.Forms.dll -r:System.Drawing.dll -r:System.Core.dll src\Program.cs
