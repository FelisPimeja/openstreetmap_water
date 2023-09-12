@REM Import environmental variables
@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i
@echo on

@REM Import OSM extract into Postgres DB
osm2pgsql -c -d %pgdb% -U %pguser% -H %pghost% -O flex -S "./water.lua" --hstore --multi-geometry %osmData%
