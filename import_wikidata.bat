@REM Import environmental variables
@echo off
for /F "eol=# tokens=*" %%i in (%~dp0\.env) do set %%i
@echo on

@REM Import Wikidata into DB
psql -U %pguser% -d %pgdb% -c ^
    "create schema if not exists water; create table if not exists water.raw_wikidata_waterways_ru (waterway text, labelru text, labelen text, sourcecoords text, mouthcoords text, mouthqid text, length numeric, gvr text, osm_id int8, tributaries text); truncate water.raw_wikidata_waterways_ru;"
psql -U %pguser% -d %pgdb% -c "\copy water.raw_wikidata_waterways_ru FROM %wikiDir%\wikidata.csv delimiter ',' csv header"
