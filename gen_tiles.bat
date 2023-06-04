@echo off
FOR /F "eol=# tokens=*" %%i IN (%~dp0\.env) DO SET %%i

@echo on
ogr2ogr -f MVT -dsco FORMAT=DIRECTORY -dsco MAXZOOM=5 -dsco COMPRESS=NO %VECTORTILESDIR% PG:"host=%PGHOST% port=%PGPORT% dbname=%PGDB% user=%PGUSER% password=%PGPASSWORD%" water.waterways_from_rels2