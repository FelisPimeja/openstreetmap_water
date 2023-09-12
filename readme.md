# [OpenStreetMap waterways validator](https://felispimeja.github.io/openstreetmap_water/) \(currently, Russia only\)

This pipeline is written for Windows (but can be easly rewriten into shell scripts). To run it you will need:
- `GDAL 3.8` (to generate PMTiles)
- `PostgreSQL` + `PostGIS` (Version >= 3.3), 
- `osm2pgsql` (Version >= 1.7.0 to use the flex output) 
- `gcloud` utility



## Usage

In the root of your project add `.env` file vith the following variables:

```shell
# PG CONNECTION DETAILS:
PGDB=YOUR_POSTGRES_DATABASE_NAME
PGUSER=YOUR_POSTGRES_USER
PGPASSWORD=YOUR_POSTGRESS_PASSWORD
PGHOST=YOUR_POSTGRES_HOST
PGPORT=YOUR_POSTGRES_HOST
PGCLIENTENCODING=CLIENT_ENCODING_WINDOWS_ONLY

# WIKIDATA PATH
WIKIDIR=PATH_TO_STORE_WIKIDATA

# OSM DATA PATH:
OSMDATA=PATH_TO_STORE_OSM_PBF
OSMDATAURL=URL_TO_DOWNLOAD_OSM_PBF
# OSMDATAURL=https://download.geofabrik.de/russia/kaliningrad-latest.osm.pbf

VECTORTILES=PATH_TO_STORE_PMTILES

# GOOGLE CLOUDE STORAGE BUCKET
BUCKETID=YOUR_GOOGLE_CLOUD_BUCKET_URL

# MAPTILER API KEY
MAPTILERKEY=YOUR_MAPTILER_KEY
```

Running `run.bat` will download and import OpenStreetMap and Wikidata datasets, proccess it, generate vector tiles in PMTiles format and upload it to Google Cloud bucket for further use on a web map (see `./docs/index.html`)