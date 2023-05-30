@echo off
FOR /F "eol=# tokens=*" %%i IN (%~dp0\.env) DO SET %%i

@echo on
osm2pgsql -c -d %PGDB% -U %PGUSER% -H %PGHOST% -O flex -S %DIR%water.lua --hstore --multi-geometry %OSMDATA%
