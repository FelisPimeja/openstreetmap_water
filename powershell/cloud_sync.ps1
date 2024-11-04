. .\import_variables.ps1

# Copy vector tiles dir into the bucket
call aws s3 cp `
    --endpoint-url=https://storage.yandexcloud.net `
    $vectorTiles s3://$bucketId/waterways.pmtiles 
