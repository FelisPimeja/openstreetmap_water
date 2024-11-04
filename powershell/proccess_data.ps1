. .\import_variables.ps1

# Process data in DB 
psql -U $pguser -d $pgdb -a -f "..\proccess_data.sql"
