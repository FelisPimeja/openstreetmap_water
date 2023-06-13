@REM Import environmental variables
@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i

@echo on
rmdir %vectorTiles% /s /q
ogr2ogr -f MVT ^
    -overwrite ^
    -progress  ^
    --debug on ^
    -dsco format=directory ^
    -dsco tile_extension=pbf ^
    -dsco conf="vector_tiles_conf.json" ^
    -dsco name="OSM watercourse errors" ^
    -dsco description="Highlighted errors for Openstreetmap watercources validator https://felispimeja.github.io/openstreetmap_water/ (currently Russia only)" ^
    -dsco type=overlay ^
    -dsco minzoom=0 ^
    -dsco maxzoom=8 ^
    -dsco extent=8192 ^
    -dsco max_size=1000000 ^
    -dsco compress=no ^
    %vectorTiles% ^
    PG:"host=%pghost% port=%pgport% dbname=%pgdb% user=%pguser% password=%pgpassword% active_schema=water" ^
    lin_0 lin_1 lin_2 lin_3 lin_4 lin_5 lin_6 lin_7 lin_8