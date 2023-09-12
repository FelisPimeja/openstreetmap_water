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