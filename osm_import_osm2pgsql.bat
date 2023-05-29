@echo off
FOR /F "eol=# tokens=*" %%i IN (%~dp0\.env) DO SET %%i

@echo on
osm2pgsql -c -d %PGDB% -U %PGUSER% -H %PGHOST% -O flex -S %DIR%water.lua --hstore --multi-geometry %DATADIR%\central-fed-district-latest.osm.pbf
@REM osm2pgsql -a -s -d %PGDB% -U %PGUSER% -H %PGHOST% -O flex -S %DIR%water.lua --hstore --multi-geometry %DATADIR%\moscow.osm.pbf
@REM osm2pgsql --cache 1024 --number-processes 4 --verbose --create --database mc --output=flex --style bus-routes.lua --slim --flat-nodes nodes.cache --hstore --multi-geometry --drop