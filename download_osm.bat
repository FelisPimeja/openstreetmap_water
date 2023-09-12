@REM Import environmental variables
@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i
@echo on

@REM Download OSM extract
cmd /c "curl %osmDataUrl% > %osmData%"
