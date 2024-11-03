@REM Import environmental variables
@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i

@echo on
del /f %vectorTiles% 
ogr2ogr -f pmtiles ^
    -overwrite ^
    -progress  ^
    --debug on ^
    -dsco conf="vector_tiles_conf.json" ^
    -dsco name="OSM watercourse errors" ^
    -dsco description="Highlighted errors for Openstreetmap watercources validator https://felispimeja.github.io/openstreetmap_water/ (currently Russia only)" ^
    -dsco type=overlay ^
    -dsco minzoom=0 ^
    -dsco maxzoom=9 ^
    -dsco extent=4096 ^
    %vectorTiles% ^
    PG:"host=%pghost% port=%pgport% dbname=%pgdb% user=%pguser% password=%pgpassword% active_schema=water" ^
    pnt_0 pnt_1 pnt_2 pnt_3 pnt_4 pnt_5 pnt_6 lin_6 lin_7 lin_8 lin_9 pol_7 pol_8 pol_9