@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i

@echo on
ogr2ogr -f MVT ^
    -dsco format=directory ^
    -dsco name="OSM watercourse errors" ^
    -dsco description="Highlighted errors for Openstreetmap watercources validator https://felispimeja.github.io/openstreetmap_water/ (currently Russia only)" ^
    -dsco type=overlay ^
    -dsco minzoom=3 ^
    -dsco maxzoom=7 ^
    -dsco compress=no ^
    %vectorTiles% ^
    PG:"host=%pghost% port=%pgport% dbname=%pgdb% user=%pguser% password=%pgpassword% active_schema=water" ^
    water_rels err_watercourse err_spring err_mouth
