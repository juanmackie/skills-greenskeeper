@echo off
rem Skills Greenskeeper - Windows launcher.
rem Delegates to Git Bash, so `greenskeeper report` works from CMD and
rem `.\greenskeeper report` works from PowerShell. Needs Git for Windows.
setlocal
set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH_EXE%" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not exist "%BASH_EXE%" (
  echo ERROR: Git Bash not found. Install Git for Windows, or run ./greenskeeper from Git Bash. 1>&2
  exit /b 1
)
"%BASH_EXE%" "%~dp0greenskeeper" %*
exit /b %ERRORLEVEL%
