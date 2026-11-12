@echo off
rem jenv for cmd.exe (also works when called from PowerShell). Part of jenv-win.
if not defined JENV_HOME for %%I in ("%~dp0..") do set "JENV_HOME=%%~fI"
if /i "%~1"=="use" goto envcmd
if /i "%~1"=="deactivate" goto envcmd
if /i "%~1"=="init" if "%~2"=="" goto envcmd
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\libexec\jenv-core.ps1" %*
exit /b %ERRORLEVEL%

rem use / deactivate / init must change THIS cmd session. The PowerShell core only prints the
rem changes as NAME=value lines (empty values are sent as __UNSET__), and this script applies them.
:envcmd
if "%~2"=="" goto envrun
echo %~2| findstr /r /c:"^[A-Za-z0-9][A-Za-z0-9._+-]*$" >nul || goto badname
:envrun
for /f "usebackq tokens=1* delims==" %%a in (`powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\libexec\jenv-core.ps1" __env %1 %2`) do set "%%a=%%b"
if "%JENV_VERSION%"=="__UNSET__" set "JENV_VERSION="
if "%JENV_ACTIVE%"=="__UNSET__" set "JENV_ACTIVE="
if "%JENV_BIN%"=="__UNSET__" set "JENV_BIN="
if "%JENV_ORIG_JAVA_HOME%"=="__UNSET__" set "JENV_ORIG_JAVA_HOME="
if "%JAVA_HOME%"=="__UNSET__" set "JAVA_HOME="
exit /b 0

:badname
echo jenv: invalid version name '%~2'. 1>&2
exit /b 1
