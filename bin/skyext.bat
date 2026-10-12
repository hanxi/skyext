@echo off
"%~dp0lua.exe" "%~dp0..\scripts\skyext.lua" %*
exit /b %ERRORLEVEL%
