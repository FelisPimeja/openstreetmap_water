SET client_min_messages TO WARNING; 


------------------------------------------
-- Proccess WikiData extract
------------------------------------------

-- First pass proccessing Wikidata dataset:
drop table if exists water.tmp_wikidata_waterways_ru cascade;
create table water.tmp_wikidata_waterways_ru as
select 
	replace(waterway, 'http://www.wikidata.org/entity/', '')   id ,
	nullif(labelru, '')                                        name_ru,
	nullif(labelen, '')                                        name_en,
	st_pointfromtext(nullif(sourcecoords, ''), 4326)           source_pnt,
	st_pointfromtext(nullif(mouthcoords,  ''), 4326)           mouth_pnt,
	st_makeline(
		st_pointfromtext(nullif(sourcecoords, ''), 4326), 
		st_pointfromtext(nullif(mouthcoords,  ''), 4326)
	)                                                          geom,
	nullif(mouthqid, '')                                       mouthq_id,
	length                                                     length_km,
	nullif(gvr, '')                                            gvr_id,
	osm_id,
	string_to_array(nullif(tributaries, ''), '; ')             tributary_id_list
from water.raw_wikidata_waterways_ru;
create index on water.tmp_wikidata_waterways_ru(id);



-- Build very simple waterway geometry from start, end points and tributary mouth points (if any):
drop table if exists water.fin_wikidata_waterways_ru cascade;
create table water.fin_wikidata_waterways_ru as 
select 
	w1.id, 
	w1.name_ru, 
	w1.name_en, 
	w1.source_pnt,
	w1.mouth_pnt,
	w1.mouthq_id,
	w1.length_km,
	w1.gvr_id,
	w1.osm_id,
	w1.tributary_id_list,
	array_agg(w2.name_ru) tributary_names_list,
	st_makeline(
		array_prepend(
			w1.source_pnt, (
				array_append(
					array_append( -- Append mouth point 2 times to form linestrings from 2 points minimum 
						array_agg(
							w2.mouth_pnt order by st_distance(
								st_transform(w1.source_pnt, 3857), 
								st_closestpoint(
									st_transform(w1.geom,3857), 
									st_transform(w2.mouth_pnt,3857)
								)
							)
						),
						w1.mouth_pnt
					),
					w1.mouth_pnt
				)
			)
		)
	) geom
from water.tmp_wikidata_waterways_ru w1
left join water.tmp_wikidata_waterways_ru w2 
	on w2.id = any(w1.tributary_id_list)
group by 
	w1.id, w1.name_ru, w1.tributary_id_list, 
	w1.source_pnt, w1.mouth_pnt, w1.geom,
	w1.name_en, w1.mouthq_id, w1.length_km,
	w1.gvr_id, w1.osm_id;

-- Create indexes 
create index on water.fin_wikidata_waterways_ru(id);
create index on water.fin_wikidata_waterways_ru(mouthq_id);
create index on water.fin_wikidata_waterways_ru(tributary_id_list);
create index on water.fin_wikidata_waterways_ru(gvr_id);
create index on water.fin_wikidata_waterways_ru using gist(source_pnt);
create index on water.fin_wikidata_waterways_ru using gist(mouth_pnt);
create index on water.fin_wikidata_waterways_ru using gist(geom);

-- Drop temporary tables
--drop table if exists water.tmp_wikidata_waterways_ru cascade;





------------------------------------------
-- Proccess OpenStreetMap extract
------------------------------------------

    
    
-- create index start_point_idx on water.osm_ways((nodes[1]));     
-- create index end_point_idx on water.osm_ways((nodes[cardinality(nodes)]));
-- create index on water.osm_areas(way_osm_id);
-- 3s


drop table if exists water.contours;
create table water.contours as 
select way_osm_id, tags, st_subdivide(st_boundary(geom)) geom
from water.osm_areas
where tags ->> 'natural' = 'water';

create index on  water.contours (way_osm_id);
create index on  water.contours using gist(geom);
-- 60s


drop table if exists water.graph_nodes;
create table water.graph_nodes as 
select distinct * from (
    select nodes[1] pnt_osm_id, st_startpoint(geom) geom 
    from water.osm_ways 
    where tags ->> 'waterway' in ('river', 'stream', 'canal', 'drain', 'ditch')
    union all
    select nodes[cardinality(nodes)] pnt_osm_id, st_endpoint(geom) geom 
    from water.osm_ways 
    where tags ->> 'waterway' in ('river', 'stream', 'canal', 'drain', 'ditch')
) a;

create index on water.graph_nodes(pnt_osm_id);
create index on water.graph_nodes using gist(geom);
--15s



drop table if exists water.graph_nodes_stat;
create table water.graph_nodes_stat as 
select 
    gn.pnt_osm_id,
    ww.way_osm_id,
    case
        when gn.pnt_osm_id = ww.nodes[1]                    then 'str'
        when gn.pnt_osm_id = ww.nodes[cardinality(nodes)]   then 'end'
        else 'mid'
    end type
from water.graph_nodes gn
join water.osm_ways ww 
    on st_intersects(gn.geom, ww.geom)
        and ww.tags ->> 'waterway' in ('river', 'stream', 'canal', 'drain', 'ditch')
union all    
select 
    gn.pnt_osm_id,
    ww.way_osm_id,
    case 
        when ww.tags ->> 'natural' = 'coastline' then 'cst' 
        else 'dam'
    end type
from water.graph_nodes gn
join water.osm_ways ww 
    on st_intersects(gn.geom, ww.geom)
        and (   ww.tags ->> 'natural' = 'coastline'
            or  ww.tags ->> 'waterway' in ('dam', 'weir')
        )
union all    
select 
    gn.pnt_osm_id,
    wc.way_osm_id,
    'bnk' type
from water.graph_nodes gn
join water.contours wc 
    on st_intersects(gn.geom, wc.geom);

create index on water.graph_nodes_stat(pnt_osm_id, type);
create index on water.graph_nodes_stat(way_osm_id);
create index on water.graph_nodes_stat(type);
-- 2m 20s



drop table if exists water.graph_nodes_stat_agg; 
create table water.graph_nodes_stat_agg as 
select 
    pnt_osm_id, 
    count(*) filter(where type = 'str')  str,
    count(*) filter(where type = 'mid')  mid,
    count(*) filter(where type = 'end') "end",
    count(*) filter(where type = 'bnk')  bnk,
    count(*) filter(where type = 'cst')  cst,
    count(*) filter(where type = 'dam')  dam
from water.graph_nodes_stat
    group by pnt_osm_id;

--create index on water.graph_nodes_stat2(pnt_osm_id);
create index on water.graph_nodes_stat_agg(str, mid, "end", bnk, cst, dam, pnt_osm_id);
create index on water.graph_nodes_stat_agg(pnt_osm_id, str, mid, "end", bnk, cst, dam);
-- 9s





-- Check for duplicated ways:
drop table if exists water.err_duplicated_ways cascade;
create table water.err_duplicated_ways as
with dups as (
    select geom 
    from water.osm_ways
    where tags ? 'waterway'
    group by geom
    having count(*) > 1
)
select ww.* 
from water.osm_ways ww
join dups using(geom);

create index err_duplicated_ways_geom_idx on water.err_duplicated_ways using gist(geom);



-- Check for duplicated areas:
drop table if exists water.err_duplicated_areas cascade;
create table water.err_duplicated_areas as 
with dups as (
    select geom 
    from water.osm_areas
    where tags ->> 'natural' in ('water', 'wetland')
    group by geom
    having count(*) > 1
)
select wa.* 
from water.osm_areas wa
join dups using(geom);

create index err_duplicated_areas_geom_idx on water.err_duplicated_areas using gist(geom);


-- Check for overlapping waterways (excluding full duplicates):
drop table if exists water.err_overlapping_ways cascade;
create table water.err_overlapping_ways as 
select 
    array[w1.way_osm_id, w2.way_osm_id] osm_ids,
    st_collectionextract(st_intersection(w1.geom, w2.geom), 2) geom
from water.osm_ways w1
join water.osm_ways w2
    on w1.way_osm_id > w2.way_osm_id
        and st_overlaps(w1.geom, w2.geom)
        and not st_equals(w1.geom, w2.geom)
        and w2.tags ? 'waterway'
where w1.tags ? 'waterway';

create index err_overlapping_ways_geom_idx on water.err_overlapping_ways using gist(geom);
-- 3m





-- Unconnected to network, connected to waterways:
drop table if exists water.err_unconnected_to_network;
create table water.err_unconnected_to_network as
select ww.way_osm_id, ww.tags, ww.geom 
from water.graph_nodes_stat_agg sa
join water.osm_ways ww
    on ww.nodes[cardinality(nodes)] = sa.pnt_osm_id
        and ww.tags ->> 'waterway' ~ 'river|stream|canal|drain|ditch'
where   sa.str = 0 
    and sa.mid = 0
    and sa.cst = 0
    and sa.bnk > 0;

create index on water.err_unconnected_to_network using gist(geom);
-- 5s




-- Waterways with possible wrong directions:
drop table if exists water.err_possible_wrong_dir cascade;
create table water.err_possible_wrong_dir as
select ww.way_osm_id, ww.tags, ww.geom 
from water.osm_ways ww
left join water.graph_nodes_stat_agg ws
    on ww.nodes[1] = ws.pnt_osm_id
left join water.graph_nodes_stat_agg we
    on ww.nodes[cardinality(nodes)] = we.pnt_osm_id
where ww.tags ->> 'waterway' ~ 'river|stream|canal|drain|ditch'
    and we.str = 0
    and (
        we.mid = 0
        and ws.mid > 0
        and we.cst = 0
    )
    or ( 
        ws."end" = 0
        and we."end" > 1
        and ws.str   > 1
    );

create index on water.err_possible_wrong_dir using gist(geom);
-- 7s





drop table if exists water.err_possible_missing_segments;
create table water.err_possible_missing_segments as
with water_points as (
    select 
        ns.way_osm_id waterarea_osm_id, 
        sa.pnt_osm_id, sa.str, sa.end, sa.bnk
    from water.graph_nodes_stat     ns
    join water.graph_nodes_stat_agg sa
        on ns.pnt_osm_id = sa.pnt_osm_id
            and sa.bnk > 0
            and sa.cst = 0
            and (   (sa.str > 0 and sa.end = 0)
                or  (sa.end > 0 and sa.str = 0)
            )
    join water.osm_areas wa 
        on wa.way_osm_id = ns.way_osm_id
            and coalesce(wa.tags ->> 'water', '') <> 'river' --and wa.way_osm_id = 332455907
    where ns.type = 'bnk' 
),
water_area as(
    select distinct  
        wp.waterarea_osm_id, 
--        st_pointonsurface(wa.geom) geom
        (st_maximuminscribedcircle(st_simplify(wa.geom, st_maxdistance(wa.geom, wa.geom) / 100))).center geom
    from water_points wp
    left join water.osm_areas wa 
        on wa.way_osm_id = wp.waterarea_osm_id
),
water_out as (
    select 
        wp.waterarea_osm_id, 
        ww.way_osm_id, 
        ww.tags, 
        st_startpoint(ww.geom) geom
    from water_points wp 
    join water.osm_ways ww 
        on ww.nodes[1] = wp.pnt_osm_id
            and ww.tags ->> 'waterway' in ('river','stream','canal','drain','ditch')
),
water_in as (
    select 
        wp.waterarea_osm_id, 
        ww.way_osm_id, 
        ww.tags, 
        st_endpoint(ww.geom) geom 
    from water_points wp 
    join water.osm_ways ww 
        on ww.nodes[cardinality(nodes)] = wp.pnt_osm_id
            and ww.tags ->> 'waterway' in ('river','stream','canal','drain','ditch')
),
con_lines as (
    select 
        wi.way_osm_id               in_osm_id,
        wa.waterarea_osm_id         wa_osm_id,
        wo.way_osm_id               out_osm_id,
        st_makeline(array[wi.geom, wa.geom, wo.geom]) geog1, -- связка через центр
        st_makeline(array[                                   -- связка через вход, ближайшую точку на отрезке центр-выход, выход
            wi.geom, 
            st_transform(st_closestpoint(st_transform(st_makeline(wa.geom, wo.geom), 3857), st_transform(wi.geom, 3857)), 4326), 
            wo.geom
        ]) geog2
    from water_area     wa
    join water_in  wi using(waterarea_osm_id)
    join water_out wo using(waterarea_osm_id)
    where wi.way_osm_id <> wo.way_osm_id                     -- точки входа и выхода не должны принадлежать одной и той же линии водного объекта
) 
select distinct on (in_osm_id)                               -- отбрасываем дубли на входных точках (один вход -> один отрезок)
    in_osm_id, 
    wa_osm_id, 
    out_osm_id, 
    case 
        when st_length(geog1::geography) < st_length(geog2::geography) then geog1 
        else geog2 
    end geom        -- Сравниваем два длины двух вариантов связки и выбираем самую короткую
from con_lines
order by in_osm_id, least(st_length(geog1::geography), st_length(geog2::geography)); -- сортируем по минимальной длине связки

create index on water.err_possible_missing_segments using gist(geom);
-- 3m 20s






drop table if exists water.err_possible_missing_segments2; 
create table water.err_possible_missing_segments2 as 
with unconnected as (
    select ww.way_osm_id, ww.tags, ww.geom, sa.pnt_osm_id
    from water.graph_nodes_stat_agg sa
    join water.osm_ways ww
        on ww.nodes[cardinality(nodes)] = sa.pnt_osm_id
            and ww.tags ->> 'waterway' ~ 'river|stream|canal|drain|ditch'
    where   sa.str = 0 
        and sa.mid = 0
        and sa.cst = 0
        and sa.bnk > 0
),
water_banks as (
    select pnt_osm_id
    from unconnected uc
    join water.graph_nodes_stat ns using(pnt_osm_id)
    join water.osm_areas wa 
        on wa.way_osm_id = ns.way_osm_id
    where ns.type = 'bnk'
        and wa.tags ->> 'water' = 'river'
)
select 
    un.way_osm_id in_osm_id,
    un.tags,
    wn.way_osm_id out_osm_id,
--    un.geom, wn.geom,
    st_makeline(st_endpoint(un.geom), st_transform(st_closestpoint(st_transform(wn.geom, 3857), st_transform(st_endpoint(un.geom), 3857)), 4326)) geom
from unconnected un
join water_banks wb using(pnt_osm_id)
left join water.err_possible_missing_segments ms 
    on ms.in_osm_id = un.way_osm_id
join lateral (
    select 
        ww.way_osm_id,
        ww.tags,
        ww.geom
    from water.osm_ways ww
    where ww.way_osm_id <> un.way_osm_id
        and ww.tags ->> 'waterway' in ('river','canal'/*,'stream','drain','ditch'*/)
        and not st_intersects(un.geom, ww.geom)
        and not ww.tags ? 'tunnel'
    order by ww.geom <-> st_endpoint(un.geom)
    limit 1
) wn on true
where ms.in_osm_id is null;
--    and un.tags ->> 'water' = 'river';

create index on water.err_possible_missing_segments2 using gist(geom);
-- 15s





drop table if exists water.err_types; 
create table water.err_types as 
with ways as (
    select ww.way_osm_id, ww.tags, ww.geom, pnt_osm_id, ww.nodes
    from water.graph_nodes_stat_agg sa
    join water.graph_nodes_stat ns using(pnt_osm_id)
    join water.osm_ways ww using(way_osm_id)
    where   sa."end" > 0
        and (sa.mid > 0 or sa.str > 0)
--        and (ww.nodes[cardinality(nodes)] = pnt_osm_id)
),
exceptions as (
    select wi.way_osm_id
    from ways wi 
    join ways wo using(pnt_osm_id)
    where   wi.nodes[cardinality(wi.nodes)] =  wi.pnt_osm_id
        and wo.nodes[cardinality(wo.nodes)] <> wo.pnt_osm_id
        and wi.tags ->> 'waterway' in ('river', 'canal')
        and wo.tags ->> 'waterway' in ('river', 'canal')
)
select wo.way_osm_id, wo.tags, wo.geom, st_endpoint(wi.geom) in_pnt
from ways               wi 
join ways               wo using(pnt_osm_id)
left join exceptions    ex 
    on ex.way_osm_id = wi.way_osm_id
where   wi.nodes[cardinality(wi.nodes)] =  wi.pnt_osm_id
    and wo.nodes[cardinality(wo.nodes)] <> wo.pnt_osm_id
    and wi.tags ->> 'waterway' in ('river', 'canal')
    and wo.tags ->> 'waterway' not in ('river', 'canal')
    and ex.way_osm_id is null;


create index on water.err_types using gist(geom);
-- 1m 35s



-----------------------------------------------------
-- Проверки тегов
-----------------------------------------------------

drop table if exists water.err_possible_tagging_mistakes;
create table water.err_possible_tagging_mistakes as 
with errors as (
    -- Culverts over 100 m long
    select
        way_osm_id, 
        '6-1' err_id
    from water.osm_ways
    where   tags ->> 'tunnel' = 'culvert'
        and st_length(geom::geography) > 100
    ---------
    union all
    ---------
    -- waterway + bridge <> 'aqueduct'
    select 
        way_osm_id,
        '6-2' err_id
    --    'http://localhost:8111/load_object?objects=w' || way_osm_id edit_in_josm,
    from water.osm_ways
    where   tags ->> 'waterway' in ('river', 'stream', 'canal', 'drain')
        and tags ->> 'bridge' <> 'aqueduct'
    ---------
    union all
    ---------
    -- Теги 'landuse' = 'reservoir'
    select 
        way_osm_id,
        case 
            when tags ->> 'landuse' = 'reservoir'
                then '6-3'
        end err_id
    --    'http://localhost:8111/load_object?objects=w' || way_osm_id edit_in_josm,
    from water.osm_areas
    where  tags ->> 'landuse' = 'reservoir'
    ---------
    union all
    ---------
    -- ключ water:type
    select 
        way_osm_id,
        case 
            when tags ? 'water:type' 
                then '6-4'
        end err_id
    --    'http://localhost:8111/load_object?objects=w' || way_osm_id edit_in_josm,
    from water.osm_areas
    where  tags ? 'water:type'
    ---------
    union all
    ---------
    -- подозрительные значения ключа water
    select 
        way_osm_id,
        case 
            when tags ->> 'water' = 'tidal'         
                and tags ->> coalesce('natural', '')  ~ '^(water|wetland)$' then '6-5-1'
            when tags ->> 'water' = 'tidal'         
                and tags ->> coalesce('natural', '') !~ '^(water|wetland)$' then '6-5-2'
            when tags ->> 'water' = 'intermittent'  
                and tags ->> coalesce('natural', '')  ~ '^(water|wetland)$' then '6-6-1'
            when tags ->> 'water' = 'intermittent'  
                and tags ->> coalesce('natural', '') !~ '^(water|wetland)$' then '6-6-2'
            when tags ->> 'water' = 'cove'                                  then '6-7-1'
            when tags ->> 'water' = 'bay'                                   then '6-7-2'
            when tags ->> 'water' = 'fishpond'                              then '6-8'
            when tags ->> 'water' = 'riverbank'                             then '6-9'
            when tags ->> 'waterway' = 'riverbank'                          then '6-10'
            when tags ->> 'water' = 'natural'                               then '6-11'
        end err_id
    --    'http://localhost:8111/load_object?objects=w' || way_osm_id edit_in_josm,
    from water.osm_areas
    where  tags ->> 'water' ~* '^(tidal|intermittent|bay|cove|fishpond|riverbank|natural)$' 
    ---------
    union all
    ---------
    -- waterway на площадных объектах
    select 
        way_osm_id,
        case 
            when tags ->> 'waterway' = 'rapids'             then '6-12'
            when tags ->> 'waterway' = 'intermittent' 
                and tags ->> 'intermittent' = 'yes'         then '6-13'
            when tags ->> 'waterway' = 'intermittent'       then '6-14'
            when tags ->> 'waterway' = 'bog'                then '6-15'
            when tags ->> 'waterway' = 'tidal'              then '6-16'
            when tags ->> 'waterway' = 'wetland'            then '6-17'
            when tags ->> 'waterway' = 'riverbank'          then '6-18'
            when tags ->> 'waterway' = 'pond'               then '6-19' 
            when tags ->> 'waterway' = 'lake'               then '6-20' 
            when tags ->> 'waterway' = 'canal'              then '6-21' 
            when tags ->> 'waterway' = 'reservoir'          then '6-22' 
            when tags ->> 'waterway' = 'oxbow'              then '6-23' 
            when tags ->> 'waterway' = 'water_point'        then '6-24' 
            when tags ->> 'waterway' = 'pressurised'        then '6-25' 
            when tags ->> 'waterway' = 'river'              then '6-26' 
            when tags ->> 'waterway' = 'pumping_station'    then '6-27'
            when tags ->> 'waterway' = 'island' 
                and st_area(geom::geography) >= 1000        then '6-28-1'
            when tags ->> 'waterway' = 'island' 
                and st_area(geom::geography) <  1000        then '6-28-2'
            when tags ->> 'waterway' = 'ditch' 
                and tags ->> 'area' = 'no'                  then '6-29-1'
            when tags ->> 'waterway' = 'ditch' 
                and not tags ? 'area'                       then '6-29-2'
            when tags ->> 'waterway' = 'drain'              then '6-30'
            when tags ->> 'waterway' = 'weir'               then '6-31' 
            when tags ->> 'waterway' = 'brook'              then '6-32'
            when tags ->> 'waterway' = 'waterfall'          then '6-33' 
            when tags ->> 'waterway' = 'lock_gate'          then '6-34' 
            when tags ?   'waterway'                        then '6-35'
        end err_id
    --    'http://localhost:8111/load_object?objects=w' || way_osm_id edit_in_josm,
    from water.osm_areas
    where   tags  ?  'waterway'
        and tags ->> 'waterway' !~ '^(dam|boatyard|dock|fuel|sluice_gate|offshore_field)$'
    ---------
    union all
    ---------
    -- water на линейных объектах
    select 
        way_osm_id,
        case 
            when tags ? 'water' 
                and (tags ->> 'natural' = 'water' or count(*) = 1)  then '6-40'
            when tags ? 'waterway' and tags ? 'water'               then '6-41'
            when tags ->> 'water' = 'spring' 
                and not tags ? 'waterway'                           then '6-42'
            when tags ->> 'waterway' = 'rapids'                     then '6-43'
            else '6-44' 
        end err_id
    from water.osm_ways, jsonb_object_keys(tags) keys
    where   tags ? 'water'
    group by way_osm_id, tags
    ---------
    union all
    ---------
    -- Слово 'Старица' в названии, не отражённое в тегах
    select 
        way_osm_id,
        case 
            when tags ->> 'name' ~* '^старица$' 
                and coalesce(tags ->> 'water', '') <> 'oxbow' then '6-45'
            when tags ->> 'name' ~* 'старица' 
                and coalesce(tags ->> 'water', '') <> 'oxbow' then '6-46'
        end err_id
    from water.osm_ways
    where   tags ->> 'name' ~* 'старица' 
        and coalesce(tags ->> 'water', '') <> 'oxbow'    
    ---------
    union all
    ---------
    -- Сокращённая статусная часть в названии на линейном объекте
    select 
        way_osm_id,
        case 
            when tags ->> 'name' ~ '(\yр\.|\yруч\.|\кан\.\y|\yпрот\.|\yовр\.|\yпор\.|\yрод\.|\yсух\.|\yб\.|\yбол\.|\yбр\.|\yвдп\.|\yвдхр\.)'    
                then '6-47'
            when tags ->> 'name' ~ '^(\yр\.|\yруч\.|\кан\.\y|\yпрот\.|\yовр\.|\yпор\.|\yрод\.|\yсух\.|\yб\.|\yбол\.|\yбр\.|\yвдп\.|\yвдхр\.)$'  
                then '6-48'
        end err_id
    from water.osm_ways
    where   tags ->> 'name' ~ '(\yр\.|\yруч\.|\кан\.\y|\yпрот\.|\yовр\.|\yпор\.|\yрод\.|\yсух\.|\yб\.|\yбол\.|\yбр\.|\yвдп\.|\yвдхр\.)'
    ---------
    union all
    ---------
    -- Сокращённая статусная часть в названии на площадном объекте
    select 
        way_osm_id,
        case 
            when tags ->> 'name' ~ '(\yр\.|\yруч\.|\кан\.\y|\yпрот\.|\yовр\.|\yпор\.|\yрод\.|\yсух\.|\yб\.|\yбол\.|\yбр\.|\yвдп\.|\yвдхр\.)'    
                then '6-47'
            when tags ->> 'name' ~ '^(\yр\.|\yруч\.|\кан\.\y|\yпрот\.|\yовр\.|\yпор\.|\yрод\.|\yсух\.|\yб\.|\yбол\.|\yбр\.|\yвдп\.|\yвдхр\.)$'  
                then '6-48'
        end err_id
    from water.osm_areas
    where   tags ->> 'name' ~ '(\yр\.|\yруч\.|\кан\.\y|\yпрот\.|\yовр\.|\yпор\.|\yрод\.|\yсух\.|\yб\.|\yбол\.|\yбр\.|\yвдп\.|\yвдхр\.|\yбол\.|\yоз\.|\yпр\.)'
    -----------
    --union all
    -----------
    -- Проверка по гидроформантам пока выключена!!!
    ---- Проверка статусной части рек по гидроформантам
    --select 
    --    way_osm_id, 
    --    tags, 
    --    '6-50' err_id,
    --    geom
    --from water.osm_ways
    --where   tags ->> 'waterway' <> 'river'
    --    and tags ->> 'name' ~* '^.+(([гвбмкшщ]|к[сш]|)а|[нл]я)$'
    --
)
select way_osm_id, array_agg(err_id) err_list
from errors 
group by way_osm_id
;
-- 20s


-- Таблица кодов ошибок
drop table if exists water.err_codes; 
create table water.err_codes as 
select *
from (
    values
        ('1',       'Дублирование геометрий объектов'),
        ('2',       'Частичное наложение геометрий объектов'),
        ('3',       'Возможно, ошибка в направлении течения'),
        ('4',       'Проблема с рангом'),
        ('5',       'Водоток не соединён с сетью'),
        -- Ошибки тегирования:
        ('6-1',     '''tunnel'' = ''culvert'' длиной более 100 м. Для протяжённых подземных коллекторов правильнее использовать ''tunnel'' = ''yes'''),
        ('6-2',     'Если это акведук (мост по которому течёт вода), то не хватает тегов ''bridge'' = ''aqueduct'''),
        ('6-3',     'Вместо ''landuse'' = ''reservoir'' рекомендуется использовать ''natural'' = ''water'' + ''water'' = ''reservoir'''),
        ('6-4',     'Ключ ''water:type'' не рекомендуется к использованию'),
        ('6-5-1',   'Устаревшие теги. Вместо ''water'' = ''tidal'' используйте ''tidal'' = ''yes'''),
        ('6-5-2',   'Устаревшие теги. Вместо ''water'' = ''tidal'' используйте ''natural'' = ''water'' + ''tidal'' = ''yes'''),
        ('6-6-1',   'Устаревшие теги. Вместо ''water'' = ''intermittent'' используйте ''intermittent'' = ''yes'''),
        ('6-6-2',   'Устаревшие теги. Вместо ''water'' = ''intermittent'' используйте ''natural'' = ''water'' + ''intermittent'' = ''yes'''),
        ('6-7-1',   'Вместо ''water'' = ''cove'' используйте  ''natural'' = ''bay'''),
        ('6-7-2',   'Вместо ''water'' = ''bay'' используйте  ''natural'' = ''bay'''),
        ('6-8',     'Вместо ''water'' = ''fishpond'' рекомендуется использовать ''water'' = ''pond'' в сочетании с ''landuse'' = ''aquaculture'' или ''leisure'' = ''fishing'''),
        ('6-9',     'Вместо ''water'' = ''riverbank'' рекомендуется использовать ''natural'' = ''water'' + ''water'' = ''river'''),
        ('6-10',    'Вместо ''waterway'' = ''riverbank'' рекомендуется использовать ''natural'' = ''water'' + ''water'' = ''river'''),
        ('6-11',    'Теги ''water'' = ''natural'' устарели'),
        ('6-12',    '''waterway'' = ''rapids'' -> ''water'' = ''rapids'''),
        ('6-13',    '''waterway'' = ''intermittent'' лучше убрать'),
        ('6-14',    '''waterway'' = ''intermittent'' -> ''intermittent'' = ''yes'''),
        ('6-15',    '''waterway'' = ''bog'' -> ''wetland'' = ''bog'''),
        ('6-16',    '''waterway'' = ''tidal'' -> ''tidal'' = ''yes'''),
        ('6-17',    '''waterway'' = ''wetland'' -> ''natural'' = ''wetland'''),
        ('6-18',    'Вместо ''waterway'' = ''riverbank'' рекомендуется использовать ''natural'' = ''water'' + ''water'' = ''river'''),
        ('6-19',    '''waterway'' = ''pond'' -> ''water'' = ''pond'''),
        ('6-20',    '''waterway'' = ''lake'' -> ''water'' = ''lake'''),
        ('6-21',    '''waterway'' = ''canal'' -> ''water'' = ''canal'''),
        ('6-22',    '''waterway'' = ''reservoir'' -> ''water'' = ''reservoir'''),
        ('6-23',    '''waterway'' = ''oxbow'' -> ''water'' = ''oxbow'''),
        ('6-24',    '''waterway'' = ''water_point'' -> ''water'' = ''water_point'''),
        ('6-25',    '''waterway'' = ''pressurised'' -> ''water'' = ''pressurised'''),
        ('6-26',    '''waterway'' = ''river'' -> ''water'' = ''river'''),
        ('6-27',    '''waterway'' = ''pumping_station'' -> ''man_made'' = ''pumping_station'''),
        ('6-28-1',  '''waterway'' = ''island'' -> ''place'' =''island'''),
        ('6-28-2',  '''waterway'' = ''island'' -> ''place'' =''islet'''),
        ('6-29-1',  '''waterway'' = ''ditch'' замкнутый контур лучше разомкнуть и убрать теги ''area'' = ''no'''),
        ('6-29-2',  '''waterway'' = ''ditch'' замкнутый контур лучше разомкнуть'),
        ('6-30',    '''waterway'' = ''drain'' не рекомендуется использовать на площадном объекте'),
        ('6-31',    '''waterway'' = ''weir'' не рекомендуется использовать на площадном объекте'),
        ('6-32',    '''waterway'' = ''brook'' не рекомендуется использовать на площадном объекте'),
        ('6-33',    '''waterway'' = ''waterfall'' не рекомендуется использовать на площадном объекте'),
        ('6-34',    '''waterway'' = ''lock_gate'' не рекомендуется использовать на площадном объекте'),
        ('6-35',    'Площадной водный объект с тегом waterway'),
        ('6-40',    'Возможно, сломанный площадной объект'),
        ('6-41',    'Вероятно, ключ ''water'' лишний'),
        ('6-42',    '''water'' = ''spring -> ''waterway'' = ''stream'''),
        ('6-43',    '''water'' = ''rapids'' -> ''waterway'' = ''rapids'''),
        ('6-44',    'Ключ ''water'' не рекомендуется использовать на линейном объекте'),
        ('6-45',    'Старица реки обозначается тегами ''waterway'' = ''oxbow''. ''Старица'' в названии не несёт смысла. Ключ ''name'' лучше убрать.'),
        ('6-46',    'Старица реки обозначается тегами ''waterway'' = ''oxbow'''),
        ('6-47',    'Нужно убрать статусную часть из названия'),
        ('6-48',    'В ключе name статусная часть вместо названия'),
        -- Гидроформанты:
        ('6-50',    'Судя по названию, это может быть ''waterway'' = ''river''')
) errs(err_id, description);




-- Все ошибки в одной таблице (с маппингом расшифровок через коды)
drop table if exists water.err_all; 
create table water.err_all as 
with errors as (
    select way_osm_id osm_id, '1' err_id from water.err_duplicated_areas
    union all
    select way_osm_id osm_id, '1' err_id from water.err_duplicated_ways
    union all
    select osm_id, '2' err_id from water.err_overlapping_ways, unnest(osm_ids) osm_id 
    union all
    select way_osm_id osm_id, '3' err_id from water.err_possible_wrong_dir
    union all
    select way_osm_id osm_id, '4' err_id from water.err_types
    union all
    select way_osm_id osm_id, '5' err_id from water.err_unconnected_to_network
    union all
    select way_osm_id osm_id, err_id 
    from water.err_possible_tagging_mistakes, unnest(err_list) err_id
)
select 
    osm_id, 
    array_agg(distinct err_id) err_ids,
    array_agg(distinct description) err_list    
from errors                 er
left join water.err_codes   ec using(err_id)
where err_id is not null
group by osm_id;

create index on water.err_all(osm_id);






