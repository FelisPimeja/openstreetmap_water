@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i

@echo on
@REM Download OSM extract
curl.exe -L -o %osmData% %osmDataUrl%

@REM Import OSM extract into Postgres DB
osm2pgsql -c -d %pgdb% -U %pguser% -H %pghost% -O flex -S %flexConf% --hstore --multi-geometry %osmData%

@REM Process data in DB 
psql -U %pguser% -d %pgdb% -a -f ".\proccess_data.sql"
