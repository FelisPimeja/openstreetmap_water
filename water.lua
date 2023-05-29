local srid = 4326
local loc_schema = 'water'
local tables = {}


tables.coast_lines = osm2pgsql.define_way_table('coast_lines', {
    { column = 'tags', type = 'jsonb' },
    { column = 'geom', type = 'linestring', projection = srid, not_null = true },
}, { schema = loc_schema })

tables.water_ways = osm2pgsql.define_way_table('water_ways', {
    { column = 'tags', type = 'jsonb' },
    { column = 'geom', type = 'linestring', projection = srid, not_null = true },
}, { schema = loc_schema })


tables.water_polygons = osm2pgsql.define_area_table('water_polygons', {
    { column = 'tags', type = 'jsonb' },
    { column = 'geom', type = 'geometry', projection = srid, not_null = true },
}, { schema = loc_schema })

tables.water_routes = osm2pgsql.define_relation_table('water_routes', {
    { column = 'tags', type = 'jsonb' },
    { column = 'geom', type = 'multilinestring', projection = srid, not_null = true },
}, { schema = loc_schema })

-- These tag keys are generally regarded as useless for most rendering. Most
-- of them are from imports or intended as internal information for mappers.
--
-- If a key ends in '*' it will match all keys with the specified prefix.
--
-- If you want some of these keys, perhaps for a debugging layer, just
-- delete the corresponding lines.
local delete_keys = {
    -- "mapper" keys
    -- 'attribution',
    -- 'comment',
    -- 'created_by',
    -- 'fixme',
    -- 'note',
    -- 'note:*',
    -- 'odbl',
    -- 'odbl:note',
    -- 'source',
    -- 'source:*',
    'source_ref',

    -- "import" keys

    -- Corine Land Cover (CLC) (Europe)
    'CLC:*',

    -- Geobase (CA)
    'geobase:*',
    -- CanVec (CA)
    'canvec:*',

    -- osak (DK)
    'osak:*',
    -- kms (DK)
    'kms:*',

    -- ngbe (ES)
    -- See also note:es and source:file above
    'ngbe:*',

    -- Friuli Venezia Giulia (IT)
    'it:fvg:*',

    -- KSJ2 (JA)
    -- See also note:ja and source_ref above
    'KSJ2:*',
    -- Yahoo/ALPS (JA)
    'yh:*',

    -- LINZ (NZ)
    'LINZ2OSM:*',
    'linz2osm:*',
    'LINZ:*',
    'ref:linz:*',

    -- WroclawGIS (PL)
    'WroclawGIS:*',
    -- Naptan (UK)
    'naptan:*',

    -- TIGER (US)
    'tiger:*',
    -- GNIS (US)
    'gnis:*',
    -- National Hydrography Dataset (US)
    'NHD:*',
    'nhd:*',
    -- mvdgis (Montevideo, UY)
    'mvdgis:*',

    -- EUROSHA (Various countries)
    'project:eurosha_2012',

    -- UrbIS (Brussels, BE)
    'ref:UrbIS',

    -- NHN (CA)
    'accuracy:meters',
    'sub_sea:type',
    'waterway:type',
    -- StatsCan (CA)
    'statscan:rbuid',

    -- RUIAN (CZ)
    'ref:ruian:addr',
    'ref:ruian',
    'building:ruian:type',
    -- DIBAVOD (CZ)
    'dibavod:id',
    -- UIR-ADR (CZ)
    'uir_adr:ADRESA_KOD',

    -- GST (DK)
    'gst:feat_id',

    -- Maa-amet (EE)
    'maaamet:ETAK',
    -- FANTOIR (FR)
    'ref:FR:FANTOIR',

    -- 3dshapes (NL)
    '3dshapes:ggmodelk',
    -- AND (NL)
    'AND_nosr_r',

    -- OPPDATERIN (NO)
    'OPPDATERIN',
    -- Various imports (PL)
    'addr:city:simc',
    'addr:street:sym_ul',
    'building:usage:pl',
    'building:use:pl',
    -- TERYT (PL)
    'teryt:simc',

    -- RABA (SK)
    'raba:id',
    -- DCGIS (Washington DC, US)
    'dcgis:gis_id',
    -- Building Identification Number (New York, US)
    'nycdoitt:bin',
    -- Chicago Building Inport (US)
    'chicago:building_id',
    -- Louisville, Kentucky/Building Outlines Import (US)
    'lojic:bgnum',
    -- MassGIS (Massachusetts, US)
    'massgis:way_id',
    -- Los Angeles County building ID (US)
    'lacounty:*',
    -- Address import from Bundesamt für Eich- und Vermessungswesen (AT)
    'at_bev:addr_date',

    -- misc
    'import',
    'import_uuid',
    'OBJTYPE',
    'SK53_bulk:load',
    'mml:class'
}

-- The osm2pgsql.make_clean_tags_func() function takes the list of keys
-- and key prefixes defined above and returns a function that can be used
-- to clean those tags out of a Lua table. The clean_tags function will
-- return true if it removed all tags from the table.
local clean_tags = osm2pgsql.make_clean_tags_func(delete_keys)

function has_water_tags(tags)
    if tags.natural == 'water' or tags.natural == 'wetland' or tags.landuse == 'reservoir' then
        return true
    end

    if tags.waterway == 'fairway' then
        return false
    end

    return tags.waterway
        or tags.harbour
        or tags.water
        or tags.wetland
end

function osm2pgsql.process_way(object)
    local tag_natural = object.tags.natural
    local tag_waterway = object.tags.waterway

    if clean_tags(object.tags) then
        return
    end

    if tag_natural == 'coastline' then
        tables.coast_lines:insert({
            tags = object.tags,
            geom = object:as_linestring()
        })
    end

    if has_water_tags(object.tags) then
        if object.is_closed then
            tables.water_polygons:insert({
                tags = object.tags,
                geom = object:as_multipolygon()
            })
        else
            if tag_waterway ~= 'dam' then
                tables.water_ways:insert({
                    tags = object.tags,
                    geom = object:as_linestring()
                })
            end
        end
    end
    
end

function osm2pgsql.process_relation(object)
    local relation_type = object:grab_tag('type')
    local tag_natural = object.tags.natural
    local tag_landuse = object.tags.landuse
    local tag_waterway = object.tags.waterway

    if clean_tags(object.tags) then
        return
    end

    if relation_type == 'waterway' and tag_waterway ~= 'fairway' then
        tables.water_routes:insert({
            tags = object.tags,
            geom = object:as_multilinestring():line_merge()
        })
    end

    if relation_type == 'multipolygon' and (tag_natural == 'water' or tag_natural == 'wetland' or tag_landuse == 'reservoir') then
        tables.water_polygons:insert({
            tags = object.tags,
            geom = object:as_multipolygon()
        })
    end
end