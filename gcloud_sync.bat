@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i

@echo on
@REM Create and copy empty file to the bucket to supress error... 
@REM ...before purging it if it's empty already
copy nul empty.txt
call gcloud storage cp empty.txt %gcloudbucket%
del empty.txt

@REM Purge bucket subdirectories
call gcloud storage rm %gcloudbucket%/**

@REM Copy vector tiles dir into the bucket
call gcloud storage cp --recursive %vectortilesdir% %gcloudbucket%
