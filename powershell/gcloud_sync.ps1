. .\import_variables.ps1

# Copy vector tiles dir into the bucket
call gcloud storage cp `
    --recursive `
    --continue-on-error `
    $vectorTiles gs://$bucketId
