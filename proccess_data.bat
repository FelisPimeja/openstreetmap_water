@REM Import environmental variables
@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i
@echo on

@REM Process data in DB 
psql -U %pguser% -d %pgdb% -a -f ".\proccess_data.sql"
