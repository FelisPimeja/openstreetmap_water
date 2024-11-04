. .\import_variables.ps1

# Import OSM extract into Postgres DB
osm2pgsql -c -d $pgdb -U $pguser -H $pghost -O flex -S "..\water.lua" $osmData
