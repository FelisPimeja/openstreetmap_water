@REM Import environmental variables
@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i

@echo on
@REM Copy vector tiles dir into the bucket
call gcloud storage cp ^
    --recursive ^
    --continue-on-error ^
    %vectorTiles% gs://%bucketId%
