---------------------------------------------

-- Build waterways hierarchy for the basemap

---------------------------------------------
-- 5m 30s

--alter role postgres set search_path = water, public;
--show work_mem;
--set  work_mem to '512MB';flююю


create index if not exists water_ways_waterway on water_ways((tags ->> 'waterway'));
create index if not exists water_ways_way_id   on water.water_ways(way_id);


-- Step 0 - Aggregate relations info
drop table if exists tmp_rels_info;
create table tmp_rels_info as 
select distinct on (1)
    (m ->> 'ref' )::int8 way_id,
    (m ->> 'role') rel_role,
    relation_id rel_id
from water_relations, jsonb_array_elements(members) m
where   m ->> 'type' = 'w'
    and m ->> 'role' in ('main_stream', 'side_stream', 'anabranch')
order by way_id, jsonb_array_length(members) desc;

create index on tmp_rels_info(way_id);
create index on tmp_rels_info(rel_role);
-- 1s

        
-- Step 1
drop table if exists tmp_ways_info_1;
create table tmp_ways_info_1 as 
select 
    way_id,
    rel_id,
    rel_role,
    coalesce(tags ->> 'waterway', '')   way_type,
    coalesce(tags ->> 'name', '')       way_name,
    st_length(geom::geography)::numeric / 1000 length_km,
    ((round((st_x((st_startpoint(geom)))::numeric) * 100000) + 18000000)::text || (round((st_y((st_startpoint(geom)))::numeric) * 100000) + 18000000)::text)::int8 start_point_id,
    ((round((st_x((  st_endpoint(geom)))::numeric) * 100000) + 18000000)::text || (round((st_y((  st_endpoint(geom)))::numeric) * 100000) + 18000000)::text)::int8 end_point_id
from water_ways w
left join tmp_rels_info r using(way_id);
--where   coalesce(tags ->> 'waterway', '') in ('river', 'canal');
-- 1m 50s

create index on tmp_ways_info_1(way_id);
create index on tmp_ways_info_1(start_point_id);
create index on tmp_ways_info_1(end_point_id);
--50 s


-- Step 2
drop table if exists tmp_points_info_1;
create table tmp_points_info_1 as           
with ids as (
    select start_point_id id from tmp_ways_info_1 
    union 
    select end_point_id   id from tmp_ways_info_1
)
select
    id,
    count(distinct s.way_id) cnt_starts,
    count(distinct e.way_id) cnt_ends
from ids i
left join tmp_ways_info_1 s on s.start_point_id = id
left join tmp_ways_info_1 e on e.end_point_id   = id
group by id;

create index on tmp_points_info_1(id);
create index on tmp_points_info_1(cnt_starts, cnt_ends);
-- 5s
-- 35s full


-- Step 3
drop table if exists tmp_ways_info_2;
create table tmp_ways_info_2 as 
select w.*,
    s.cnt_starts    cnt_s_starts,
    s.cnt_ends      cnt_s_ends,
    e.cnt_starts    cnt_e_starts,
    e.cnt_ends      cnt_e_ends
from tmp_ways_info_1 w
left join tmp_points_info_1 s on s.id = w.start_point_id
left join tmp_points_info_1 e on e.id = w.end_point_id
where not (
    s.cnt_starts = 1
    and s.cnt_ends = 0
    and e.cnt_starts = 0
    and e.cnt_ends = 1
);

create index on tmp_ways_info_2(start_point_id); --!!!
create index on tmp_ways_info_2(end_point_id);   --!!!
-- 25s



-- Step 4   
drop table if exists built_waterways_1a;
create  table built_waterways_1a as
--
with recursive segments as (
    select 
        0::int2 i,
        way_id start_way_id,
        way_id,
        way_name,
        rel_id,
--        rel_role,
        start_point_id,
        end_point_id,
        cnt_s_starts,
        cnt_s_ends,
        cnt_e_starts,
        cnt_e_ends,
        array[way_id]   way_id_arr,
        length_km
    from tmp_ways_info_2
    where  cnt_s_ends   = 0         -- 1. Very first segment
        or cnt_s_ends   > 1         -- 2. First segments after waterways merge
        or cnt_s_starts > 1         -- 3. Fork teeth
        or way_id in (              -- 4. Name different from the previous segment
            select i1.way_id
            from tmp_ways_info_2 i1
            join tmp_ways_info_2 i2 
                on i2.end_point_id = i1.start_point_id
                    and i2.way_name <> i1.way_name
            where i1.way_name <> ''
        )
    --
    union all 
    --
    select
        (s1.i + 1)::int2,
        s1.start_way_id,
        s2.way_id,
        s1.way_name,
        coalesce(s1.rel_id, s2.rel_id),
        s1.start_point_id,
        s2.end_point_id,
        s1.cnt_s_starts,
        s1.cnt_s_ends,
        s2.cnt_e_starts,
        s2.cnt_e_ends,
        s1.way_id_arr || s2.way_id,
        s1.length_km + s2.length_km
    from segments s1 
    left join tmp_ways_info_2 s2
        on s2.start_point_id = s1.end_point_id
            and (s1.way_name = coalesce(nullif(s2.way_name, ''), s1.way_name) or s1.rel_id = s2.rel_id)
            and not array[s2.way_id] <@ s1.way_id_arr
    where s1.cnt_e_starts = 1
        and s1.cnt_e_ends = 1
        and s2.way_id is not null
),
segments_merged as (
    select distinct on (start_way_id) * from segments order by start_way_id, i desc
)
select distinct on (way_id) * from segments_merged order by way_id, i desc, length_km desc;

create index on built_waterways_1a(start_point_id); --!!!
create index on built_waterways_1a(end_point_id);   --!!!
create index on built_waterways_1a(cnt_s_ends, way_id, way_name, length_km, end_point_id, cnt_s_ends, cnt_e_starts, cnt_e_ends);
-- 2s
-- 26m full!!!!!!!!!!!!!!!

-- Step 5  
drop table if exists built_waterways_1b;
create  table built_waterways_1b as
--
with recursive segments as (
    select 
        i i_orig,
        0::int2 i,
        start_way_id,
        way_id,
        way_name,
        rel_id,
--        rel_role,
        start_point_id,
        end_point_id,
        cnt_s_starts,
        cnt_s_ends,
        cnt_e_starts,
        cnt_e_ends,
        way_id_arr,
        length_km
    from built_waterways_1a
    where cnt_s_ends = 0         -- 1. Very first segment
        or way_name <> ''
    --
    union all 
    --
    select
        s1.i_orig,
        (s1.i + 1)::int2,
        s1.start_way_id,
        s2.way_id,
        coalesce(s1.way_name, s2.way_name),
        coalesce(s1.rel_id, s2.rel_id),
        s1.start_point_id,
        s2.end_point_id,
        s1.cnt_s_starts,
        s1.cnt_s_ends,
        s2.cnt_e_starts,
        s2.cnt_e_ends,
        s1.way_id_arr || s2.way_id_arr,
        s1.length_km + s2.length_km
    from segments s1 
    left join lateral (
        select s2.* from built_waterways_1a s2
        where s2.start_point_id = s1.end_point_id
            and (s1.way_name = coalesce(nullif(s2.way_name, ''), s1.way_name) or s1.rel_id = s2.rel_id)
            and not array[s2.way_id] <@ s1.way_id_arr
        order by s2.way_name = s1.way_name desc, s2.length_km desc
        limit 1
    ) s2 on true 
    where s2.way_id is not null
),
segments_merged as (
    select distinct on (way_id, end_point_id) * from segments order by way_id, end_point_id, i desc
),
segments_filtered as (
    select distinct on (way_id, start_point_id) * from segments_merged order by way_id, start_point_id, i desc, length_km desc
)
select distinct on (way_name, start_point_id) * from segments_filtered order by way_name, start_point_id, i desc, length_km desc;


create index on built_waterways_1b(start_point_id); --!!!
create index on built_waterways_1b(end_point_id);   --!!!
-- 1s
-- 11s full


-- Step 6 - Gather all watercourses together
drop table if exists built_waterways_1c;
create table built_waterways_1c as 
--
-- Find waterways from Step 4 that were not used in Step 5 by "start_way_id":
with a as ( 
    select a.* 
    from built_waterways_1a a
    left join built_waterways_1b b using(start_way_id)
    where b.start_way_id is null
),
-- Double check them against Step 5 intersecting way arrays:
b as (select start_way_id, unnest(way_id_arr) way_id from a),
c as (select unnest(way_id_arr) way_id from built_waterways_1b),
d as (
    select distinct b.start_way_id
    from b
    left join c using(way_id)
    where c.way_id is null
),
e as (
    select a.start_way_id
    from built_waterways_1a a
    join d using(start_way_id)
),
-- Find waterways that were not used in Step 4:
f as (
    select w1.way_id 
    from      tmp_ways_info_1 w1 
    left join tmp_ways_info_2 w2 using(way_id)
    where w2.way_id is null
),
-- Gather it all together:
united as (
        select 
            start_way_id way_id,
            way_name,
            rel_id,
            way_id_arr,
            length_km
        from built_waterways_1b
    union all
        select 
            start_way_id way_id,
            way_name,
            rel_id,
            way_id_arr,
            length_km
        from built_waterways_1a
        join e using(start_way_id)
    union all 
        select 
            w.way_id,
            w.way_name,
            w.rel_id,
            array[w.way_id] way_id_arr,
            w.length_km
        from tmp_ways_info_1 w
        join f using(way_id)
)
-- Join geometry:
select 
    a.*, 
    st_endpoint(g1.geom) end_pnt,
    st_linemerge(st_collect(g2.geom), true) geom
from united a
cross join unnest(way_id_arr) u
left join water_ways g1 on g1.way_id = way_id_arr[array_upper(way_id_arr, 1)]
left join water_ways g2 on g2.way_id = u
group by a.way_id, a.way_name, a.rel_id, a.way_id_arr, a.length_km, g1.geom;

create index on built_waterways_1c (length_km);
create index on built_waterways_1c using gist(geom);
-- 50s
-- 2m 30s full


--Step 7 - Building waterways hierarchy
drop table if exists built_waterways_1d;
create table built_waterways_1d as 
--
with recursive h1 as (
    select w1.way_id, w2.way_id parent_way_id
    from      built_waterways_1c w1
    left join built_waterways_1c w2 
        on st_intersects(w1.end_pnt, w2.geom)
            and w1.way_id <> w2.way_id
            and not st_equals(w1.end_pnt, w2.end_pnt)
),
h2 as (
    select 
        1::int2 way_rank, 
        way_id, 
        parent_way_id,
        array[way_id] way_id_arr
    from h1
    where parent_way_id is null 
    union
    select 
        (h2.way_rank + 1)::int2, 
        h1.way_id, 
        h1.parent_way_id,
        h2.way_id_arr || h1.way_id
    from h1
    join h2
        on h2.way_id = h1.parent_way_id
) cycle way_id set is_cycle using journey_ids,
a as (
    select distinct on (way_id) way_id, h2.way_id_arr 
    from h2 where not is_cycle
    order by way_id, way_rank
),
b as (
    select distinct on (b.way_id) b.way_id, cardinality(way_id_arr) - rn + 1 way_rank
    from a, unnest(way_id_arr) with ordinality b(way_id, rn)
    order by b.way_id, way_rank desc
)
select distinct on (h2.way_id) b.way_rank, parent_way_id, w.*  
from  built_waterways_1c w
left join b using(way_id)
left join h2
    on h2.way_id = w.way_id;

create index on built_waterways_1d (way_rank);
create index on built_waterways_1d (way_id);
create index on built_waterways_1d using gist(geom);
--55s
--  SQL Error [53200]: ERROR: out of memory
--  Detail: Failed on request of size 1776 in memory context "RecursiveUnion hash table".

-- SQL Error [53200]: ERROR: out of memory
-- Detail: Failed on request of size 378 in memory context "Caller tuples".
show shared_buffers;
set shared_buffers = '512MB';


--Step 8 - Segmentaze and rank segments of parental waterways:
drop table if exists built_waterways_1e;
create table built_waterways_1e as 
--
-- Query waterways that have at least 1 tributary
with a as (
    select distinct on (p.way_id, c.way_rank)
        c.way_rank,                 -- tributary rank
        p.way_id,                   -- parent way id
        round(st_length(
            st_linesubstring(
                p.geom,
                0,
                st_linelocatepoint(p.geom, c.end_pnt)
            )::geography
        )::numeric / 1000, 2) dist, -- calc distance from parent spring point to tributary mouth point (for sorting tributaries)
        st_linelocatepoint(p.geom, c.end_pnt) end_fract   -- save fraction from parent spring point to tributary mouth point
    from built_waterways_1d p
    join built_waterways_1d c
        on c.parent_way_id = p.way_id 
            and st_geometrytype(p.geom) = 'ST_LineString' -- !!!!!!!!!! check and prevent MultiLinestrings creation on previous steps
    order by p.way_id, c.way_rank, dist
),
b as (
    select 
        way_id, 
        way_rank,
        dist,
        end_fract,
        coalesce(lag(way_rank) over(partition by way_id order by dist), 0) lag_rank, 
        coalesce(lag(dist)     over(partition by way_id order by dist), 0) lag_dist
    from a
),
c as (
    select 
        row_number() over(partition by way_id) id, 
        way_id, way_rank, 
        coalesce(lag(end_fract) over(partition by way_id order by dist), 0) start_fract,
        end_fract
    from b 
    where  way_rank > coalesce(lag_rank, 0)
        and   dist >= coalesce(lag_dist, 0)
),
d as (
    select 
        way_id, 
        case when id = 1 then 1 else way_rank end way_rank, -- reset rank to 1 for the first segment
        start_fract,
        end_fract
    from c where end_fract <> start_fract
    union all (
    -- generate data for the last waterway segment:
    select distinct on(way_id)
        way_id, 
        way_rank + 1 way_rank, 
        end_fract start_fract, 
        1 end_fract 
    from c order by way_id, id desc
))
(select 
    p.way_id, 
    d.way_rank,
    p.parent_way_id,
    p.way_name,
    p.rel_id,
    st_linesubstring(p.geom, d.start_fract, d.end_fract) geom
from d 
join built_waterways_1d p using(way_id)
order by way_id)
union all
(select 
    p.way_id, 
    p.way_rank,
    p.parent_way_id,
    p.way_name,
    p.rel_id,
    p.geom
from built_waterways_1d p 
left join built_waterways_1d c
    on c.parent_way_id = p.way_id 
where c.way_id is null);

create index on built_waterways_1d (way_rank);
create index on built_waterways_1d (way_id);
create index on built_waterways_1d using gist(geom);

-- 3m 50s










---------------------------------------------

-- Data validation

---------------------------------------------


-- Waterway dead ends:
drop table if exists water.dead_ends; 
create table water.dead_ends as 
select st_endpoint(w1.geom) pnt, w1.* 
from water.water_ways w1
left join water.water_ways w2
	on st_intersects(st_endpoint(w1.geom), w2.geom)
		and w2.way_id <> w1.way_id
left join water.coast_lines c
	on st_intersects(st_endpoint(w1.geom), c.geom)
where  w2.way_id is null
	and c.way_id is null;
	



drop table if exists water.a1;
create table water.a1 as 
select 
	(st_dump(st_union(geom))).geom geom
from water.water_ways
where tags ->> 'waterway' in ('river', 'stream', 'canal');


drop table if exists water.a2;
create table water.a2 as 
select 
	(st_dump(st_linemerge(st_union(geom), true))).geom geom
from water.water_ways
where tags ->> 'waterway' in ('river', 'stream', 'canal');



-- Merging waterways geometry with minimum side effects (no attributes unfortunately!)
drop table if exists water.a3;
create table water.a3 as 
select 
	(st_dump(st_linemerge(st_collect(geom), true))).geom geom
from water.water_ways
where tags ->> 'waterway' in ('river', 'stream', 'canal');




drop table if exists water.a4;
create table water.a4 as

--explain
with filtered as (
	select * from water.water_ways
	where tags ->> 'waterway' in ('river', 'stream', 'canal')
),
lines_merged as (
	select 
		(st_dump(st_linemerge(st_collect(geom), true))).geom geom
	from filtered
)
select
	array_agg(f.way_id) way_ids,
	array_agg(f.tags ->> 'name'),
	l.geom
from lines_merged l
left join filtered f
	on st_contains(l.geom, st_collect(st_startpoint(f.geom), st_endpoint(f.geom)))
group by l.geom
limit 1



-- Recursively building waterways
-- Problem: infinite loop if waterway ways area forming circle root!!!
-- 2m 18s for Central Federal District in Russia
drop table if exists water.a5;
create table water.a5 as
--
with recursive waterways as (
	(
		with filtered as (
			select way_id, st_transform(geom, 4326) geom
			from water.water_ways w
			where tags ->> 'waterway' in ('river')
		)
		select 
			1 i, 
			f1.*, 
			f1.way_id id, 
			null::int8 prev_way_id,
			array[f1.way_id] ids_array
		from filtered f1
		left join filtered f2 
			on st_startpoint(f1.geom) = st_endpoint(f2.geom)
		where f2.way_id is null
	)
	union all
	(
		with filtered as (
			select way_id, st_transform(geom, 4326) geom
			from water.water_ways w
			where tags ->> 'waterway' in ('river')
		),   
		prev_ways as (
			select f1.*, f2.way_id prev_way_id
			from filtered f1
			left join filtered f2 
				on st_startpoint(f1.geom) = st_endpoint(f2.geom)
		)
		select 
			i + 1 i,
			p.way_id, 
			st_collect(w.geom, p.geom) geom,
			w.id,
			p.prev_way_id,
			w.ids_array || p.way_id ids_array
		from waterways w 
		left join prev_ways p
			on w.way_id = p.prev_way_id
		where p.way_id is not null
	)
)
--select * from waterways;
--
select distinct on (id) * 
from waterways
order by id, i desc

-- Removind circle forming duplicate!:
delete from water.water_ways where way_id  = 677306284;


select 'Water ways (river) segments count'      category, count(*) from water.water_ways where tags ->> 'waterway' = 'river' union all
select 'Water ways after recursive merge count' category, count(*) from water.a5;






-- First pass proccessing Wikidata dataset:
drop table if exists water.wikidata_tmp1;
create table water.wikidata_tmp1 as
select 
	replace(waterway, 'http://www.wikidata.org/entity/', '') id ,
	nullif(labelru, '') name_ru,
	nullif(labelen, '') name_en,
	st_pointfromtext(nullif(sourcecoords, ''), 4326) source_pnt,
	st_pointfromtext(nullif(mouthcoords,  ''), 4326) mouth_pnt,
	st_makeline(
		st_pointfromtext(nullif(sourcecoords, ''), 4326), 
		st_pointfromtext(nullif(mouthcoords,  ''), 4326)
	) geom,
	nullif(mouthqid, '') mouthq_id,
	length length_km,
	nullif(gvr, '') gvr_id,
	osm_id,
	string_to_array(nullif(tributaries, ''), '; ') tributary_id_list
from water.wikidata_waterways_russia;
create index on water.wikidata_tmp1(id);



-- Build very simple waterway geometry from start, end points and tributary mouth points (if any):
drop table if exists water.wikidata_proccessed;
create table water.wikidata_proccessed as 
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
from water.wikidata_tmp1 w1
left join water.wikidata_tmp1 w2 
	on w2.id = ANY(w1.tributary_id_list)
group by 
	w1.id, w1.name_ru, w1.tributary_id_list, 
	w1.source_pnt, w1.mouth_pnt, w1.geom,
	w1.name_en, w1.mouthq_id, w1.length_km,
	w1.gvr_id, w1.osm_id;

-- Create indexes 
create index on water.wikidata_proccessed(id);
create index on water.wikidata_proccessed(mouthq_id);
create index on water.wikidata_proccessed(tributary_id_list);
create index on water.wikidata_proccessed(gvr_id);
create index on water.wikidata_proccessed using gist(source_pnt);
create index on water.wikidata_proccessed using gist(mouth_pnt);
create index on water.wikidata_proccessed using gist(geom);

-- Drop temporary tables
drop table if exists water.wikidata_tmp1;





---------------------------------------------------

select w.*, array_agg((m ->> 'ref')::int8) mems
from water.water_relations w
cross join jsonb_array_elements(members) m
group by w.relation_id, w.tags, w.members 


-- Waterway relations with suspicious member roles
select distinct
	relation_id, 
	tags ->> 'name' 		name,
	tags ->> 'name:ru' 		name_ru,
	tags ->> 'name:en' 		name_en,
	tags ->> 'wikipedia' 	wikipedia,
	tags ->> 'wikidata' 	wikidata,
	tags, 
	members
from water2.water_relations w
cross join jsonb_array_elements(members) m
where 	(m ->> 'type' = 'r' )
	or  (m ->> 'type' = 'n' and m ->> 'role' not in ('spring', 'mouth'))
	or  (m ->> 'type' = 'w' and m ->> 'role' not in ('main_stream', 'side_stream', 'anabranch'))
	
	or 	m ->> 'type' = 'r'

	
	
	
drop table if exists water.a1;
create table water.a1 as	
select
	relation_id, 
	tags ->> 'name' 		name,
	tags ->> 'name:ru' 		name_ru,
	tags ->> 'name:en' 		name_en,
	tags ->> 'wikipedia' 	wikipedia,
	tags ->> 'wikidata' 	wikidata,
	'https://ru.wikipedia.org/wiki/' || (tags ->> 'wikipedia')::text wikipedia_link, 
	'https://www.wikidata.org/wiki/' || (tags ->> 'wikidata' )::text wikidata_link, 
	'https://www.openstreetmap.org/relation/' || relation_id osm_rel_link,
	'http://localhost:8111/load_object?objects=r' || relation_id || '&relation_members=true' josm_link,
	tags, 
	members,
	geom
from water.waterways_from_rels w




create index on water.water_relations(members);



-- Gather geometry from waterway relations
drop table if exists water.waterways_from_rels;
create table water.waterways_from_rels as 
select 
	r.relation_id,
	r.tags,
	r.members,
	st_linemerge(st_collect(w.geom), true) geom
from water.water_relations r
cross join jsonb_array_elements(members) m
left join water.water_ways w 
	on w.way_id = (m ->> 'ref')::int8
where m ->> 'type' = 'w'
group by r.relation_id, r.tags, r.members;

create index on water.waterways_from_rels using gist(geom);




select * from water.water_relations wr 



alter table water2.wikidata_waterways_russia  set schema water


-----------------------------

select json_agg(a)
from (
	select
		relation_id, 
		tags ->> 'name' 		name,
		tags ->> 'name:ru' 		name_ru,
		tags ->> 'name:en' 		name_en,
		tags ->> 'wikipedia' 	wikipedia,
		tags ->> 'wikidata' 	wikidata--,
	--	'https://ru.wikipedia.org/wiki/' || (tags ->> 'wikipedia')::text wikipedia_link, 
	--	'https://www.wikidata.org/wiki/' || (tags ->> 'wikidata' )::text wikidata_link, 
	--	'https://www.openstreetmap.org/relation/' || relation_id osm_rel_link,
	--	'http://localhost:8111/load_object?objects=r' || relation_id || '&relation_members=true' josm_link--,
	--	tags, 
	--	members,
	--	geom
	from water.waterways_from_rels w
) a




-- How many rivers (streams and canals) with distinct names 
-- and wiki tags are there not in waterway relations (2933)
with ways_in_rels as (
	select (m ->> 'ref')::int8 way_id
	from water.water_relations r
	cross join jsonb_array_elements(members) m
	where m ->> 'type' = 'w'
		and m ->> 'role' in ('main_streal', 'side_stream', 'anabranch')
)
select count(distinct w.tags ->> 'name') cnt_name
from water.water_ways w 
left join ways_in_rels r using(way_id)
where r.way_id is null
	and w.tags ->> 'waterway' in ('river', 'stream', 'canal')
	and (w.tags ? 'wikipedia' or w.tags ? 'wikidata')

	
	
	
-- Create separate table for waterways that are not in waterway relations
drop table if exists water.waterways_not_in_rels;
create table water.waterways_not_in_rels as
with ways_in_rels as (
	select (m ->> 'ref')::int8 way_id
	from water.water_relations r
	cross join jsonb_array_elements(members) m
	where   m ->> 'type' = 'w'
		and m ->> 'role' in ('main_stream', 'side_stream', 'anabranch')
)
select w.*
from water.water_ways w 
left join ways_in_rels r using(way_id)
where r.way_id is null;

create index on water.waterways_not_in_rels using gist(geom);
	
	
	


-- Check waterway relation for multiple springs and mouths
-- (possibly pointing on errors)
-- todo: 
--	- Add check for multiple mouths sharing the same way or relation
drop table if exists water.waterways_from_rels2;
create table water.waterways_from_rels2 as 
with segments_raw as (
	select 
		relation_id,
		(st_dump(geom)).geom geom 
	from water.waterways_from_rels
),
segments as (
	select 	row_number() over(partition by relation_id) segment_id, *
	from segments_raw
),
springs as (
	select 
		s1.relation_id, 
		st_collect(st_startpoint(s1.geom)) spring
	from segments s1
	left join segments s2
		on s1.relation_id = s2.relation_id
			and s1.segment_id <> s2.segment_id
			and st_intersects(st_startpoint(s1.geom), s2.geom)
	where s2.relation_id is null
	group by s1.relation_id 
),
mouths as (
	select  
		s1.relation_id, 
		st_collect(st_endpoint(s1.geom)) mouth
	from segments s1
	left join segments s2
		on s1.relation_id = s2.relation_id
			and s1.segment_id <> s2.segment_id
			and st_intersects(st_endpoint(s1.geom), s2.geom)
	where s2.relation_id is null
	group by s1.relation_id 
)
select w.*, spring, mouth
from water.waterways_from_rels w
left join springs using(relation_id)
left join mouths  using(relation_id);
	
	
create view water.err_watercourse as
select relation_id,	tags, geom 
from water.waterways_from_rels2 
where st_numgeometries(spring) > 1 
	or st_numgeometries(mouth) > 1;

create view water.err_spring as
select relation_id,	spring 
from water.waterways_from_rels2 
where st_numgeometries(spring) > 1;

create view water.err_mouth as
select relation_id,	mouth 
from water.waterways_from_rels2 
where st_numgeometries(mouth) > 1;

create view water.not_in_rels as
select 
	way_id, 
	tags ->> 'waterway' "type",	
	tags ->> 'name' "name",	
	tags - 'waterway' - 'name' tags, 
	geom 
from water.waterways_not_in_rels;

create or replace view water.water_rels as
select 
	a.relation_id, 
	a.tags ->> 'waterway' "type",	
	a.tags ->> 'name' "name",	
	a.tags - 'waterway' - 'name' tags, 
	a.geom 
from water.waterways_from_rels a 
--left join water.waterways_from_rels2 b using(relation_id)
--where b.relation_id not in (select relation_id from water.waterways_from_rels2);




--------------------------------------------------------

-- Find rivers and canals that flow into smaller watercourses (streams, ditches)
drop table if exists water.err_ranks;
create table water.err_ranks as 
select 
	w1.way_id,
	w1.tags ->> 'waterway' "type",
	w1.geom --, w2.way_id, w2.tags ->> 'waterway' "type2"
from water.water_ways w1
left join water.water_ways w2
	on st_intersects(st_endpoint(w1.geom), w2.geom)
		and w2.tags ->> 'waterway' in ('stream', 'ditch', 'drain')
left join water.water_ways w3
	on w3.way_id <> w1.way_id 
		and w3.tags ->> 'waterway' in ('river', 'canal')
		and st_intersects(st_endpoint(w1.geom), w3.geom)
where   w1.tags ->> 'waterway' in ('river', 'canal')
	and w2.way_id is not null
	and w3.way_id is null;

create index on water.ranks using gist(geom);




-- Find watercourses segments with incorrect flow direction
-- ~7 min - Maybe try to separate in steps with temp tables?
drop table if exists water.err_directions;
create table water.err_directions as 
-- 2 ways with common end point not continueing in start point of another way
select 
	w1.way_id,
	w1.geom
from water.water_ways w1
left join water.water_ways w2
	on w1.way_id <> w2.way_id
		and st_intersects(st_endpoint(w1.geom), w2.geom)
		and (st_endpoint(w1.geom) = st_startpoint(w2.geom)	
			or (    not st_equals(st_endpoint(w1.geom),   st_endpoint(w2.geom))
				and not st_equals(st_endpoint(w1.geom), st_startpoint(w2.geom))
			)
		)
left join water.water_ways w3
	on w1.way_id <> w3.way_id
		and st_intersects(st_endpoint(w1.geom), w3.geom)
		and st_endpoint(w1.geom) = st_endpoint(w3.geom)	
left join water.coast_lines c -- Check for sharing end point with coastline
	on st_intersects(st_endpoint(w1.geom), c.geom)
where w2.way_id is null
	and w3.way_id is not null
	and c.way_id is null
union all 
-- 2 ways with common start point not continueing in end point of another way
select 
	w1.way_id,
	w1.geom
from water.water_ways w1
left join water.water_ways w2
	on w1.way_id <> w2.way_id
		and st_intersects(st_startpoint(w1.geom), w2.geom)
		and (st_startpoint(w1.geom) = st_endpoint(w2.geom)	
			or (    not st_equals(st_startpoint(w1.geom),   st_endpoint(w2.geom))
				and not st_equals(st_startpoint(w1.geom), st_startpoint(w2.geom))
			)
		)
left join water.water_ways w3
	on w1.way_id <> w3.way_id
		and st_intersects(st_startpoint(w1.geom), w3.geom)
		and st_startpoint(w1.geom) = st_startpoint(w3.geom)	
left join water.coast_lines c -- Check for sharing start point with coastline
	on st_intersects(st_startpoint(w1.geom), c.geom)
where w2.way_id is null
	and w3.way_id is not null
	and c.way_id is null;

create index on water.err_directions using gist(geom);

	

	
create index on water.water_ways using gist((st_endpoint(geom)));
create index on water.water_ways using gist((st_startpoint(geom)));
create index on water.water_ways (way_id);
create index on water.water_ways (way_id, st_endpoint(geom), st_startpoint(geom));
create index on water.water_ways using gist (st_endpoint(geom), st_startpoint(geom));

	


	
select distinct tags ->> 'waterway'
from water.water_ways 
where tags ? 'waterway'


-------------------------------------------------------------
create index on water.waterways_from_rels2 using gist(geom);
create index on water.waterways_from_rels2 using gist(mouth);




-- Intersecting waterways and water areas without common intersection points:
with intersections as (

select wa.*, ww.*
--    ww.way_id,
--    wa.area_id
from water.water_ways ww
join water.water_areas wa 
    on st_intersects(ww.geom, wa.geom)
        and wa.type <> 'wetland'
left join water.planet_osm_ways lw 
    on lw.id = ww.way_id
left join water.planet_osm_ways aw 
    on aw.id = wa.area_id
where not lw.nodes && aw.nodes

)
select * from intersections;


SELECT rolpassword FROM pg_authid
WHERE rolname = 'postgres';


-- Intersecting waterways and water areas without common intersection points:
-- todo: Добавить проверку и отбрасывать пересечения с внутренними поперечными линиями рек
drop table if exists water.err_intersect_area_way_no_point;
create table water.err_intersect_area_way_no_point as 
select 
    ww.osm_id way_id,
    wa.osm_id area_id,
--    wa.geom, ww.geom,
--    st_intersection(st_boundary(wa.geom), ww.geom) geom1,
    st_startpoint(st_intersection(st_boundary(wa.geom), ww.geom)) geom
from water.ways ww
join water.areas wa 
    on st_intersects(ww.geom, wa.geom)
        and wa.tags ->> 'natural' <> 'wetland'
where 
    ww.tags ->> 'waterway' not in ('weir', 'dam')   -- отбрасываем дамбы
    and not ww.nodes && wa.nodes
    and not st_within(ww.geom, wa.geom);            -- отбрасываем линии которые полностью внутри площадного водоёма и заведомо не должны иметь точек пересечения

create index on water.err_intersect_area_way_no_point using gist(geom);
-- ~95s

select count(*) from water.areas where tags ->> 'natural' <> 'wetland';
select count(*) from water.ways;

