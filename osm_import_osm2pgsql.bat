@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i

@echo on
osm2pgsql -c -d %pgdb% -u %pguser% -h %pghost% -o flex -s %flexConf% --hstore --multi-geometry %osmData%
