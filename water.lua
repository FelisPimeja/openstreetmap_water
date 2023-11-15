local srid = 4326
local loc_schema = 'water'
local tables = {}



tables.nodes = osm2pgsql.define_table({
    name = 'nodes', 
    schema = loc_schema,
    ids = { type = 'node', id_column = 'osm_id' },
    columns = {
        { column = 'tags', type = 'jsonb' },
        { column = 'geom', type = 'point', projection = srid, not_null = true },
    }, 
    indexes = {
        { column = 'tags', method = 'btree' },
        { column = 'geom', method = 'gist' },
    }
})

tables.ways = osm2pgsql.define_table({
    name = 'ways', 
    schema = loc_schema,
    ids = { type = 'way', id_column = 'osm_id' },
    columns = {
        { column = 'tags', type = 'jsonb' },
        { column = 'nodes', sql_type = 'int8[]' },
        { column = 'geom', type = 'linestring', projection = srid, not_null = true },
    }, 
    indexes = {
        { column = 'tags', method = 'btree' },
        { column = 'nodes', method = 'gin' },
        { column = 'geom', method = 'gist' },
    }
})

tables.areas = osm2pgsql.define_table({
    name = 'areas', 
    schema = loc_schema,
    ids = { type = 'area', id_column = 'osm_id' },
    columns = {
        { column = 'tags', type = 'jsonb' },
        { column = 'nodes', sql_type = 'int8[]' },
        { column = 'geom', type = 'geometry', projection = srid, not_null = true },
    }, 
    indexes = {
        { column = 'tags', method = 'btree' },
        { column = 'nodes', method = 'gin' },
        { column = 'geom', method = 'gist' },
    }
})

tables.relations = osm2pgsql.define_table({
    name = 'relations', 
    schema = loc_schema,
    ids = { type = 'relation', id_column = 'osm_id' },
    columns = {
        { column = 'tags', type = 'jsonb' },
        { column = 'members', type = 'jsonb' },
    }, 
    indexes = {
        { column = 'tags', method = 'btree' },
        { column = 'members', method = 'btree' },
    }
})



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
local w2r = {}

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

function osm2pgsql.process_node(object)
    local natural = object.tags.natural
    local waterway = object.tags.waterway

    if clean_tags(object.tags) then
        return
    end

    if natural == 'water' or natural == 'spring' or natural == 'hot_spring' or natural == 'geyser' or waterway then
        tables.nodes:insert({
            tags = object.tags,
            geom = object:as_point()
        })
    end
end

function osm2pgsql.process_way(object)

    if clean_tags(object.tags) then
        return
    end

    if has_water_tags(object.tags) then
        if object.is_closed then
            tables.areas:insert({
                tags = object.tags,
                nodes = '{' .. table.concat(object.nodes, ',') .. '}',
                geom = object:as_multipolygon()
            })
        else
            tables.ways:insert({
                tags = object.tags,
                nodes = '{' .. table.concat(object.nodes, ',') .. '}',
                geom = object:as_linestring()
            })
        end
    end
    
end

function osm2pgsql.process_relation(object)
    local type = object.tags.type
    local natural = object.tags.natural
    local landuse = object.tags.landuse
    local waterway = object.tags.waterway
    local members = object.members

    if clean_tags(object.tags) then
        return
    end

    if type == 'waterway' then
        tables.relations:insert({
            tags = object.tags,
            members = object.members
        })
    end

    if type == 'multipolygon' and (natural == 'water' or natural == 'wetland' or landuse == 'reservoir') then


        -- If there is any data from parent relations, add it in
        -- local d = w2r[object.id]
        -- if d then
        --     local refs = {}
        --     local ids = {}
        --     for rel_id, rel_ref in pairs(d) do
        --         refs[#refs + 1] = rel_ref
        --         ids[#ids + 1] = rel_id
        --     end
        --     table.sort(refs)
        --     table.sort(ids)
        --     row.rel_refs = table.concat(refs, ',')
        --     row.rel_ids = '{' .. table.concat(ids, ',') .. '}'
        -- end

        -- for _, member in ipairs(object.members) do
        --     if member.type == 'w' then
        --         if not w2r[member.ref] then
        --             w2r[member.ref] = {}
        --         end
        --         w2r[member.ref][object.id] = object.tags.ref
        --     end
        -- end

        -- for member in pairs(object.members) do
        --     if member.type == 'w' then
        --         nod_list = '{' .. table.concat(member.nodes, ',') .. '}'
        --     end
        -- end

        tables.areas:insert({
            tags = object.tags,
            -- nodes = nod_list,
            geom = object:as_multipolygon()
        })
    end

end
