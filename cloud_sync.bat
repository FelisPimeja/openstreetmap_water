@REM Import environmental variables
@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i

@echo on
@REM Copy vector tiles dir into the bucket
call aws s3 cp ^
    --endpoint-url=https://storage.yandexcloud.net ^
    %vectorTiles% s3://%bucketId%/waterways.pmtiles 
