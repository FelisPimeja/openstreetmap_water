@REM Import environmental variables
@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i
@echo on


@REM Download WikiData Query results as CSV file
curl.exe --output %wikiDir%\wikidata.csv ^
    --request POST https://query.wikidata.org/sparql ^
    --header "Accept: text/csv" ^
    --data-urlencode query@wikidata_watercources.rq ^
    --retry-all-errors

@REM Import Wikidata into DB
psql -U %pguser% -d %pgdb% -c ^
    "create schema if not exists water; create table if not exists water.wikidata_waterways_russia (waterway text, labelru text, labelen text, sourcecoords text, mouthcoords text, mouthqid text, length numeric, gvr text, osm_id int8, tributaries text); truncate water.wikidata_waterways_russia;"
psql -U %pguser% -d %pgdb% -c "\copy water.wikidata_waterways_russia FROM %wikiDir%\wikidata.csv delimiter ',' csv header"

@REM Download OSM extract
cmd /c "curl %osmDataUrl% > %osmData%"

@REM Import OSM extract into Postgres DB
osm2pgsql -c -d %pgdb% -U %pguser% -H %pghost% -O flex -S %flexConf% --hstore --multi-geometry %osmData%

@REM Process data in DB 
psql -U %pguser% -d %pgdb% -a -f ".\proccess_data.sql"
