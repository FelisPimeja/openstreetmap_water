alter role postgres set search_path = water, public;


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


-- Watercourse hierarchy
select w1.*, w2.relation_id parent_id
from water.waterways_from_rels2 w1
left join water.waterways_from_rels2 w2 
	on st_intersects(w1.mouth, w2.geom)



create index on water.water_rels

select  "type", count(*) cnt from water.water_areas group by "type" order by cnt desc;

'water',
'lake',
'wetland',
'pond',
'marsh',
'bog',
'swamp',
'river',
'oxbow',
'reedbed',
'reservoir',
'wet_meadow',
'wastewater',
'fen',
'basin',
'tidalflat',
'saltmarsh',
'canal'

----------------------------------------------------------
create index if not exists water_ways_waterway on water_ways((tags ->> 'waterway'));
create index if not exists water_ways_way_id   on water.water_ways(way_id);

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

--select distinct tags ->> 'waterway', count(*) cnt from water_ways group by 1 order by cnt desc;
--
--select * from water_ways 
--where tags ? 'waterway' is false 
--	and tags ->> 'natural' not in ('water', 'wetland');
--
--select * from water_ways 
--where tags ->> 'waterway' = 'waterfall';

drop table if exists tmp_ways_info;
create table tmp_ways_info as 
select 
	way_id,
	rel_id,
	rel_role,
	coalesce(tags ->> 'waterway', '') 	way_type,
	coalesce(tags ->> 'name', '') 		way_name,
	st_length(geom::geography)::numeric / 1000 length_km,
	((round((st_x((st_startpoint(geom)))::numeric) * 100000) + 18000000)::text || (round((st_y((st_startpoint(geom)))::numeric) * 100000) + 18000000)::text)::int8 start_id,
	((round((st_x((  st_endpoint(geom)))::numeric) * 100000) + 18000000)::text || (round((st_y((  st_endpoint(geom)))::numeric) * 100000) + 18000000)::text)::int8 end_id
from water_ways w
left join tmp_rels_info r using(way_id)
where   coalesce(tags ->> 'waterway', '') not in ('lock_gate', 'weir', 'waterfall', '')
	and coalesce(tags ->> 'natural',  '') not in ('water', 'wetland')
-- 1m 50s

create index on tmp_ways_info(way_id);
create index on tmp_ways_info(rel_id);
create index on tmp_ways_info(rel_role);
create index on tmp_ways_info(way_type);
create index on tmp_ways_info(way_name);
create index on tmp_ways_info(start_id);
create index on tmp_ways_info(end_id);
--15 s

--select way_id from tmp_ways_info group by way_id having count(*) > 1;
--select distinct rel_role from tmp_ways_info;

drop table if exists tmp_points_info;
create table tmp_points_info as 			
with ids as (
	select start_id id from tmp_ways_info 
	union 
	select end_id   id from tmp_ways_info
)
select
	id,
	count(distinct s.way_id) cnt_starts,
--	array_agg(s.way_id) start_ways_agg,
--	array_agg(e.way_id) end_ways_agg,
	count(distinct e.way_id) cnt_ends
from ids i
left join tmp_ways_info s on s.start_id = id
left join tmp_ways_info e on e.end_id   = id
group by id;

create index on tmp_points_info(id);
create index on tmp_points_info(cnt_starts, cnt_ends);
-- 25s


-- Destinations for dead ends (end without starts)
--with ends as (select * from pnt_stat where cnt_starts = 0)
--select w2.start_pnt, w1.geom, w2.geom
--from ways w1
--join ends e 
--	on e.id = w1.end_id
--join ways w2
--	on st_intersects(w1.geom, w2.start_pnt)
--		and w1.way_id <> w2.way_id;


	
------------------------------------------------------------
-- Recursive watercourse building
------------------------------------------------------------
drop table if exists water.tmp_ways_info2;
create table water.tmp_ways_info2 as 
select w.*
from tmp_ways_info w
join tmp_points_info s 
	on w.start_id = s.id
join tmp_points_info e 
	on w.end_id   = e.id
where not (s.cnt_starts = 1
	and  s.cnt_ends = 0
	and  e.cnt_starts = 0
	and  e.cnt_ends = 1
	);

create index on tmp_ways_info2(way_id);
create index on tmp_ways_info2(rel_id);
create index on tmp_ways_info2(rel_role);
create index on tmp_ways_info2(way_type);
create index on tmp_ways_info2(way_name);
create index on tmp_ways_info2(start_id);
create index on tmp_ways_info2(end_id);
-- 15s


drop table if exists water.tmp_built_waterways1;
create table water.tmp_built_waterways1 as
--
with recursive waterway as (
	select 
		1 i, 
		w.way_id,
		w.way_id 		way_id_orig,
		array[w.way_id] way_ids_arr,
		w.start_id,
		w.end_id,
		w.way_name,
		w.rel_id
	from tmp_ways_info2 w
	join tmp_points_info s 
		on s.id = w.start_id
	join tmp_points_info e 
		on e.id = w.end_id
	where  e.cnt_starts = 1 
		and (s.cnt_ends > 1
			or (s.cnt_starts > 0 and s.cnt_ends = 0)
			or (s.cnt_starts > 1 and s.cnt_ends = 1)
		)
	--
	union all
	--
	select 
		i + 1 i, 
		w2.way_id,
		w1.way_id_orig,
		w1.way_ids_arr || w2.way_id 									way_ids_arr,
		w1.start_id,
		w2.end_id,
		coalesce(nullif(w1.way_name, ''), nullif(w2.way_name, ''), '')	way_name,
		coalesce(w1.rel_id, w2.rel_id)									rel_id
	from waterway w1
	left join tmp_ways_info2 w2	
		on w1.end_id = w2.start_id
			and w2.way_id <> all(w1.way_ids_arr)
			and (coalesce(nullif(w2.way_name,''), w1.way_name) = coalesce(nullif(w1.way_name, ''), w2.way_name) -- check whether name is the same or blank
				or coalesce(w2.rel_id, w1.rel_id, 0) = coalesce(w1.rel_id, w2.rel_id, 0)						-- check whether relation_id is the same or null
			)
	join tmp_points_info s
		on s.id = w2.start_id
			and s.cnt_starts = 1
			and s.cnt_ends = 1
	where w2.way_id is not null
)
select distinct on(way_id_orig) * 
from waterway 
order by way_id_orig, i desc;
-- 2m 10s



drop table if exists water.tmp_built_waterways2;
create table water.tmp_built_waterways2 as
with recursive waterway as ((
	with ways_used as (
		select unnest(way_ids_arr) way_id from tmp_built_waterways1
	),
	ways_left as materialized(
		select
			w.way_id, 
			w.start_id, 
			w.end_id, 
			w.way_name, 
			w.rel_id
		from tmp_ways_info2 w
		left join ways_used u using(way_id)
		where u.way_id is null
	),
	ids as (
		select start_id id from ways_left union 
		select end_id   id from ways_left
	),
	stat as materialized(
		select id, count(w1.*) cnt_starts, count(w2.*) cnt_ends
		from ids i
		left join ways_left w1 on w1.start_id = id
		left join ways_left w2 on w2.end_id   = id
		group by id
	)
	select
		1 i, 
		w.way_id,
		w.way_id 		way_id_orig,
		array[w.way_id] way_ids_arr,
		w.start_id,
		w.end_id,
		w.way_name,
		w.rel_id
	from ways_left w
	join stat s1 
		on s1.id = w.start_id
	where s1.cnt_starts > 0  
		and s1.cnt_ends = 0		
	)
	--
	union all
	--
	select 
		i + 1 i, 
		w2.way_id,
		w1.way_id_orig,
		w1.way_ids_arr || w2.way_id 									way_ids_arr,
		w1.start_id,
		w2.end_id,
		coalesce(nullif(w1.way_name, ''), nullif(w2.way_name, ''), '')	way_name,
		coalesce(w1.rel_id, w2.rel_id)									rel_id
	from waterway w1
	join tmp_points_info e 
		on w1.end_id = e.id
			and e.cnt_starts = 1
	left join tmp_ways_info2 w2	
		on w1.end_id = w2.start_id
			and w2.way_id <> all(w1.way_ids_arr)
			and (coalesce(nullif(w2.way_name,''), w1.way_name) = coalesce(nullif(w1.way_name, ''), w2.way_name) -- check whether name is the same or blank
				or coalesce(w2.rel_id, w1.rel_id, 0) = coalesce(w1.rel_id, w2.rel_id, 0)						-- check whether relation_id is the same or null
			)
			where w2.way_id is not null
)
select distinct on(way_id_orig) * 
from waterway 
order by way_id_orig, i desc;
-- 10s 


drop table if exists built_waterways;
create table built_waterways as
--
with used_ways as (
	select *
	from (
		select unnest(way_ids_arr) way_id from tmp_built_waterways1 union all
		select unnest(way_ids_arr) way_id from tmp_built_waterways2
	) u
) 
select 
	i.way_id way_id_orig,
	array[i.way_id] way_ids_arr,
	0 i,
	i.way_name,
	i.rel_id,
	array[i.rel_role] rel_roles_arr,
	i.length_km,
	g.geom
from tmp_ways_info 	 i
left join water_ways g using(way_id)
left join used_ways  u using(way_id)
where u.way_id is null
--
union all 
--
select 
	c.way_id_orig,
	c.way_ids_arr,
	c.i 												iterations,
	max(w.way_name) 									name,
	max(w.rel_id) filter(where w.rel_id is not null) 	rel_id,
	array_agg(distinct w.rel_role) filter(where w.rel_role is not null) 	rel_roles_arr,
	sum(length_km) 										length_km,
	st_linemerge(st_collect(g.geom) ,true)				geom
from (
	select * from tmp_built_waterways1 union all
	select * from tmp_built_waterways2
) c
left join tmp_ways_info w 
	on w.way_id = any(c.way_ids_arr)
left join water_ways g
	on g.way_id = w.way_id
group by c.way_id_orig,	c.way_ids_arr, c.i;

create index on built_waterways using gist(geom);
-- 4m 10s



-------------------------


drop table if exists tmp_points_debug;
create table tmp_points_debug as
with points as (
	select 
		((round((st_x((st_startpoint(geom)))::numeric) * 100000) + 18000000)::text || (round((st_y((st_startpoint(geom)))::numeric) * 100000) + 18000000)::text)::int8 start_id,
		((round((st_x((  st_endpoint(geom)))::numeric) * 100000) + 18000000)::text || (round((st_y((  st_endpoint(geom)))::numeric) * 100000) + 18000000)::text)::int8 end_id,
		i > 0 is_i,
		st_startpoint(geom) start_pnt,
		st_endpoint(geom) end_pnt
	from built_waterways
),
points2 as (
	select start_id id, is_i, start_pnt geom from points union all
	select end_id   id, is_i, end_pnt   geom from points
)
select *
from points2
left join tmp_points_info using(id);

create index on tmp_points_debug (is_i);
create index on tmp_points_debug using gist(geom);
-- 35s



----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------




-- Step 1
drop table if exists tmp_ways_info_1;
create table tmp_ways_info_1 as 
select 
	way_id,
	rel_id,
	rel_role,
	coalesce(tags ->> 'waterway', '') 	way_type,
	coalesce(tags ->> 'name', '') 		way_name,
	st_length(geom::geography)::numeric / 1000 length_km,
	((round((st_x((st_startpoint(geom)))::numeric) * 100000) + 18000000)::text || (round((st_y((st_startpoint(geom)))::numeric) * 100000) + 18000000)::text)::int8 start_point_id,
	((round((st_x((  st_endpoint(geom)))::numeric) * 100000) + 18000000)::text || (round((st_y((  st_endpoint(geom)))::numeric) * 100000) + 18000000)::text)::int8 end_point_id
from water_ways w
left join tmp_rels_info r using(way_id)
where   coalesce(tags ->> 'waterway', '') in ('river', 'canal');
--order by geom;
-- 1m 50s

create index on tmp_ways_info_1(way_id);
--create index on tmp_ways_info_1(rel_id);
--create index on tmp_ways_info_1(rel_role);
--create index on tmp_ways_info_1(way_type);
--create index on tmp_ways_info_1(way_name);
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
--	array_agg(s.way_id) start_ways_agg,
--	array_agg(e.way_id) end_ways_agg,
	count(distinct e.way_id) cnt_ends
from ids i
left join tmp_ways_info_1 s on s.start_point_id = id
left join tmp_ways_info_1 e on e.end_point_id   = id
group by id;

create index on tmp_points_info_1(id);
create index on tmp_points_info_1(cnt_starts, cnt_ends);
-- 5s



-- Step 3
drop table if exists tmp_ways_info_2 cascade;
create table tmp_ways_info_2 as 
select w.*,
	s.cnt_starts 	cnt_s_starts,
	s.cnt_ends 		cnt_s_ends,
	e.cnt_starts 	cnt_e_starts,
	e.cnt_ends 		cnt_e_ends
from tmp_ways_info_1 w
left join tmp_points_info_1 s on s.id = w.start_point_id
left join tmp_points_info_1 e on e.id = w.end_point_id
where not (
	s.cnt_starts = 1
	and s.cnt_ends = 0
	and e.cnt_starts = 0
	and e.cnt_ends = 1
);

--create index on tmp_ways_info_2(way_id);
--create index on tmp_ways_info_2(rel_id);
--create index on tmp_ways_info_2(rel_role);
--create index on tmp_ways_info_2(way_type);
--create index on tmp_ways_info_2(way_name);
create index on tmp_ways_info_2(start_point_id); --!!!
--create index on tmp_ways_info_2(start_point_id, length_km desc); --!!!
create index on tmp_ways_info_2(end_point_id);   --!!!
--create index on tmp_ways_info_2(end_point_id, cnt_e_ends);
--
--create index on tmp_ways_info_2(cnt_s_starts);
--create index on tmp_ways_info_2(cnt_s_ends, length_km);
--create index on tmp_ways_info_2(cnt_s_ends);
create index on tmp_ways_info_2(cnt_s_ends, way_id, way_name, length_km, end_point_id, cnt_s_ends, cnt_e_starts, cnt_e_ends);
--create index on tmp_ways_info_2(cnt_s_ends, length_km, way_id, way_name, end_point_id, cnt_s_ends, cnt_e_starts, cnt_e_ends);
--create index on tmp_ways_info_2(length_km);
--create index on tmp_ways_info_2(cnt_e_starts);
--create index on tmp_ways_info_2(cnt_e_ends);
-- 5s
--vacuum analyze tmp_ways_info_2;


--show work_mem;
--set  work_mem to '512MB';



	
-- Step 4	
drop table if exists built_waterways_9;
create  table built_waterways_9 as
--
--explain --(analyze, costs, verbose, buffers/*, format json*/)
with recursive waterways as ((
	select 
		0::int2 i,
		0::int2 d,
		way_id start_way_id,
		way_id,
		null::int8 start_way_id_w2,
		rel_id,
		way_name,
		length_km,
		end_point_id,
		0::int2 cnt_s_ends,
		cnt_e_starts,
		cnt_e_ends,
		null::bool w2_way_id_not_null,
		null::int2 w2_cnt_s_ends, 
		array[way_id] 	way_id_arr,
		array[way_name] way_name_arr,
		array[round(length_km, 1)::text] length_arr,
		1::int2 state 			-- 0 - increment, 1 - stage, 2 - stop
	from water.tmp_ways_info_2
	where (cnt_s_ends = 0       -- 1. Watercourse spring
	   or way_id in (          -- 2. Watercource with another name starts from the neighbouring segment
            select i2.way_id
            from tmp_ways_info_2 i1
            join tmp_ways_info_2 i2 
                on i1.cnt_s_ends = 1
                    and i1.way_name <> ''
                    and i2.way_name <> ''
                    and i1.rel_id <> i2.rel_id
                    and i1.way_name <> i2.way_name
                    and i1.end_point_id = i2.start_point_id
            left join tmp_ways_info_2 i3 
                on i3.way_id <> i1.way_id
                    and i1.end_point_id = i3.end_point_id
                    and (i2.way_name = i3.way_name or i2.rel_id = i3.rel_id)
            where i3.way_id is null
        )
        or way_id in (         -- 3. Side streams
            select distinct i2.way_id
            from tmp_ways_info_2 i1
            join lateral (
                select i2.*
                from tmp_ways_info_2 i2
                where i2.start_point_id = i1.end_point_id
                    and i2.cnt_s_ends   > 0
                    and i2.cnt_s_starts > 1
                    and (i2.way_name = i1.way_name or i2.way_name = '' or coalesce(i2.rel_id, 0) = coalesce(i1.rel_id, 0))
                order by coalesce(i2.rel_role, '') = 'main_stream' desc, i2.length_km desc
                offset 1
            ) i2 on true
        )
        )
--      and way_id in (49023690, 645862054, 643464031, 1080226012, 1080226011, 645286195)
--      and way_id in (488835926, 277857313, 80139755, 52014307)
--      and way_id in (1136030753, 167622095, 189387571, 133844514, 125212490, 45493455, 56026202, 46546001, 1175254738, 1175254743, 56191081, 1175254746, 32756823, 56195804, 531440157, 531439621, 262537582)
--	limit 40000
	)
	--
	union all (
	--
	with w as (select * from waterways)
	select
--  i:
--		(w1.i + 1)::int2 i,
		case 
            when w1.cnt_e_ends = 1 then 
                case 
                    when w1.cnt_e_starts = 0                                        then w1.i
                    when w1.cnt_e_starts > 0 then
                        case
                            when c.way_id is not null                               then (w1.i + 1)::int2
                            else                                                         w1.i
                        end
                    else                                                                 null::int2
                end
            when w1.cnt_e_ends > 1 then 
                case 
                    when w2.way_id is not null and w2.cnt_s_ends = 0 then 
                        case
                            when (w1.way_name = w2.way_name 
                                or coalesce(w1.rel_id, 0) = coalesce(w2.rel_id, 0)
                                ) 
                                and w2.length_km > w1.length_km                     then w1.i
                            else
                                case
                                    when c.way_id is not null                       then (w1.i + 1)::int2
                                    else                                                 w1.i
                                end
                        end
                    else                                                                 w1.i
                end
            else                                                                         null::int2
        end,
--	d:
		(w1.d + 1)::int2,
--	start_way_id
        w1.start_way_id,
--  way_id:
        case 
            when w1.cnt_e_ends = 1 then 
                case 
                    when w1.cnt_e_starts = 0                                        then coalesce(w1.way_id, -3)
                    when w1.cnt_e_starts > 0 then
                        case
                            when c.way_id is not null                               then coalesce( c.way_id, -4)
                            else                                                         w1.way_id
                        end
                    else                                                                 -1
                end
            when w1.cnt_e_ends > 1 then 
                case 
                    when w2.way_id is not null 
                        and w2.cnt_s_ends = 0 then 
                        case
                            when (w1.way_name = w2.way_name 
                                or coalesce(w1.rel_id, 0) = coalesce(w2.rel_id, 0)
                                ) 
                                and w2.length_km > w1.length_km                     then coalesce(w1.way_id, -5)
                            else
                                case
                                    when c.way_id is not null                       then  c.way_id
                                    else                                                 w1.way_id
                                end
                        end
                    else                                                                 w1.way_id
                end
            else                                                                         -2
        end,
--  start_way_id_w2:
        w2.start_way_id,
--  rel_id:
        case 
            when w1.cnt_e_ends = 1 then 
                case 
                    when w1.cnt_e_starts = 0                                        then w1.rel_id
                    when w1.cnt_e_starts > 0 then
                        case
                            when c.way_id is not null                               then  c.rel_id
                            else                                                         w1.rel_id
                        end
                    else                                                                 null
                end
            when w1.cnt_e_ends > 1 then 
                case 
                    when w2.way_id is not null and w2.cnt_s_ends = 0 then 
                        case
                            when (w1.way_name = w2.way_name 
                                or coalesce(w1.rel_id, 0) = coalesce(w2.rel_id, 0)
                                ) 
                                and w2.length_km > w1.length_km                     then w1.rel_id
                            else
                                case
                                    when c.way_id is not null                       then  c.rel_id
                                    else                                                 w1.rel_id
                                end
                        end
                    else                                                                 w1.rel_id
                end
            else                                                                         null
        end,
--  way_name:
		coalesce(w1.way_name, c.way_name),
--	length_km:
        case 
            when w1.cnt_e_ends = 1 then 
                case 
                    when w1.cnt_e_starts = 0                                        then w1.length_km
                    when w1.cnt_e_starts > 0 then
                        case
                            when c.way_id is not null                               then w1.length_km + c.length_km
                            else                                                         w1.way_id
                        end
                    else                                                                 null
                end
            when w1.cnt_e_ends > 1 then 
                case 
                    when w2.way_id is not null and w2.cnt_s_ends = 0 then 
                        case
                            when (w1.way_name = w2.way_name 
                                or coalesce(w1.rel_id, 0) = coalesce(w2.rel_id, 0)
                                ) 
                                and w2.length_km > w1.length_km                     then w1.length_km
                            else
                                case
                                    when c.way_id is not null                       then w1.length_km + c.length_km
                                    else                                                 w1.length_km
                                end
                        end
                    else                                                                 w1.length_km
                end
            else                                                                         null
        end,
--  end_point_id:
        case 
            when w1.cnt_e_ends = 1 then 
                case 
                    when w1.cnt_e_starts = 0                                        then w1.end_point_id
                    when w1.cnt_e_starts > 0 then
                        case
                            when c.way_id is not null                               then  c.end_point_id
                            else                                                         w1.end_point_id
                        end
                    else                                                                 null
                end
            when w1.cnt_e_ends > 1 then 
                case 
                    when w2.way_id is not null and w2.cnt_s_ends = 0 then 
                        case
                            when (w1.way_name = w2.way_name 
                                or coalesce(w1.rel_id, 0) = coalesce(w2.rel_id, 0)
                                ) 
                                and w2.length_km > w1.length_km                     then w1.end_point_id
                            else
                                case
                                    when c.way_id is not null                       then c.end_point_id
                                    else                                                 w1.end_point_id
                                end
                        end
                    else                                                                 w1.end_point_id
                end
            else                                                                         null
        end,
--  cnt_s_ends:
		w1.cnt_s_ends,
--	cnt_e_starts:
        case 
            when w1.cnt_e_ends = 1 then 
                case 
                    when w1.cnt_e_starts = 0                                        then w1.cnt_e_starts
                    when w1.cnt_e_starts > 0 then
                        case
                            when c.way_id is not null                               then  c.cnt_e_starts
                            else                                                         w1.cnt_e_starts
                        end
                    else                                                                 null
                end
            when w1.cnt_e_ends > 1 then 
                case 
                    when w2.way_id is not null and w2.cnt_s_ends = 0 then 
                        case
                            when (w1.way_name = w2.way_name 
                                or coalesce(w1.rel_id, 0) = coalesce(w2.rel_id, 0)
                                ) 
                                and w2.length_km > w1.length_km                     then w1.cnt_e_starts
                            else
                                case
                                    when c.way_id is not null                       then c.cnt_e_starts
                                    else                                                 w1.cnt_e_starts
                                end
                        end
                    else                                                                 w1.cnt_e_starts
                end
            else                                                                         null
        end,
--  cnt_e_ends:
        case 
            when w1.cnt_e_ends = 1 then 
                case 
                    when w1.cnt_e_starts = 0                                        then w1.cnt_e_ends
                    when w1.cnt_e_starts > 0 then
                        case
                            when c.way_id is not null                               then  c.cnt_e_ends
                            else                                                         w1.cnt_e_ends
                        end
                    else                                                                 null
                end
            when w1.cnt_e_ends > 1 then 
                case 
                    when w2.way_id is not null and w2.cnt_s_ends = 0 then 
                        case
                            when (w1.way_name = w2.way_name 
                                or coalesce(w1.rel_id, 0) = coalesce(w2.rel_id, 0)
                                ) 
                                and w2.length_km > w1.length_km                     then w1.cnt_e_ends
                            else                                                          c.cnt_e_ends
                        end
                    else                                                                 w1.cnt_e_ends
                end
            else                                                                         null
        end,
--  w2_way_id is not null:
        w2.way_id is not null,
--  w2_cnt_s_ends:
        w2.cnt_s_ends,
--  way_id_arr:
        case 
            when w1.cnt_e_ends = 1 then 
                case 
                    when w1.cnt_e_starts = 0                                        then w1.way_id_arr
                    when w1.cnt_e_starts > 0 then
                        case
                            when c.way_id is not null                               then w1.way_id_arr || c.way_id
                            else                                                         w1.way_id_arr
                        end
                    else                                                                 null
                end
            when w1.cnt_e_ends > 1 then 
                case 
                    when w2.way_id is not null and w2.cnt_s_ends = 0 then 
                        case
                            when (w1.way_name = w2.way_name 
                                or coalesce(w1.rel_id, 0) = coalesce(w2.rel_id, 0)
                                ) 
                                and w2.length_km > w1.length_km                     then w1.way_id_arr
                            else
                                case
                                    when c.way_id is not null                       then w1.way_id_arr || c.way_id
                                    else                                                 w1.way_id_arr
                                end
                        end
                    else                                                                 w1.way_id_arr
                end
            else                                                                         null
        end,
--  way_name_arr:
		case when w1.cnt_e_ends = 1 or ( w1.cnt_e_ends <> 1 and w2.start_way_id is not null and w1.length_km > w2.length_km) then w1.way_name_arr || c.way_name else w1.way_name_arr end,
--	length_arr:
		case when w1.cnt_e_ends = 1 or ( w1.cnt_e_ends <> 1 and w2.start_way_id is not null and w1.length_km > w2.length_km) then w1.length_arr || (round(w1.length_km, 1) || '/' || round(coalesce(w2.length_km, 0), 1)) else w1.length_arr end,
--	state:
		case 
			when w1.cnt_e_ends = 1 then 
    			case 
    				when w1.cnt_e_starts = 0                                        then 2::int2
                    when w1.cnt_e_starts > 0 then
                        case
                            when c.way_id is not null                               then 0::int2
                            else                                                         2::int2
                        end
                    else                                                                 5::int2
    			end
            when w1.cnt_e_ends > 1 then 
                case 
    				when w2.way_id is not null and w2.cnt_s_ends = 0 then 
    				    case
                            when (w1.way_name = w2.way_name 
                                or coalesce(w1.rel_id, 0) = coalesce(w2.rel_id, 0)
                                ) 
                                and w2.length_km > w1.length_km                     then 2::int2
                            else
                                case
                                    when c.way_id is not null                       then 0::int2
                                    else                                                 2::int2
                                end
        				end
    				else                                                                 1::int2
				end
            else                                                                         6::int2
		end
	from w w1
	left join lateral (
		select w2.* from w w2
		where w1.start_way_id <> w2.start_way_id
			and w1.end_point_id = w2.end_point_id
		order by w2.length_km desc
		limit 1
	) w2 on true
	left join lateral (
		select c.* 
		from water.tmp_ways_info_2 c
		where c.start_point_id = w1.end_point_id
			and c.cnt_s_ends > 0
			and not array[c.way_id] <@ w1.way_id_arr
            and (c.way_name = w1.way_name or coalesce(c.rel_id, 0) = coalesce(w1.rel_id, 0))
 		order by c.length_km desc
		limit 1
	) c on true
	where 
		w1.state <> 2
		and w1.d < 300
)) --cycle start_way_id, way_id set is_cycle using waterways_array
--select * from waterways /*where not is_cycle*/ order by start_way_id, d;
,
way_info as (
	select distinct on (start_way_id) * 
	from waterways
	order by start_way_id, d desc
) 
--select * from way_info;
select 
	w1.i,
	w1.start_way_id,
    w1.way_id,
    w1.rel_id,
	w1.way_name,
	w1.length_km,
	w1.end_point_id,
	w1.cnt_s_ends,
	w1.cnt_e_starts,
	w1.cnt_e_ends,
	w2_way_id_not_null,
    w2_cnt_s_ends,
	w1.way_id_arr,
	w1.way_name_arr,
	w1.length_arr,
	w1.state,
	st_collect(g.geom) geom,
	max(w1.d) max_d
from way_info w1, unnest(way_id_arr) a
left join water_ways g on g.way_id = a
group by 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16;


create index on built_waterways_9(max_d);
create index on built_waterways_9 using gist (geom);



select *
from water.tmp_ways_info_2
where cnt_s_ends = 0

select i1.way_name, i2.way_name, i1.end_point_id, i2.start_point_id, w1.geom, w2.geom
from tmp_ways_info_2 i1
join tmp_ways_info_2 i2 
    on i1.cnt_s_ends = 1
--        and i1.way_id > i2.way_id
        and i1.way_name <> ''
        and i2.way_name <> ''
        and i1.way_name <> i2.way_name
        and i1.end_point_id = i2.start_point_id
left join water_ways w1 on w1.way_id = i1.way_id
left join water_ways w2 on w2.way_id = i2.way_id
        
select coalesce(nullif('', ''), 'null1') <> coalesce(nullif('имя', ''), 'null2') --'имя'


select distinct i2.way_id
from tmp_ways_info_2 i1
join lateral (
    select i2.*
    from tmp_ways_info_2 i2
    where i2.cnt_s_starts > 1
        and i2.cnt_s_ends > 0
        and i2.start_point_id = i1.end_point_id
        and (i2.way_name = i1.way_name or coalesce(i2.rel_id, 0) = coalesce(i1.rel_id, 0))
    order by i2.length_km desc
    offset 1
) i2 on true

left join water_ways w1 on w1.way_id = i1.way_id
left join water_ways w2 on w2.way_id = i2.way_id
    
    
    
tmp_ways_info_2 i2 
    on i1.cnt_s_ends = 1
--        and i1.way_id > i2.way_id
        and i1.way_name <> ''
        and i2.way_name <> ''
        and i1.way_name <> i2.way_name
        and i1.end_point_id = i2.start_point_id
left join water_ways w1 on w1.way_id = i1.way_id
left join water_ways w2 on w2.way_id = i2.way_id


-- Visualize starting segments for recursive watercoarses building
drop table if exists tmp_starts;
create table tmp_starts as 
with a as (
    select 
        w.*,
        i.way_name,
        i.way_type,
        i.rel_id,
        i.cnt_s_starts,
        i.cnt_s_ends,
        i.cnt_e_starts,
        i.cnt_e_ends,
        case 
            when cnt_s_ends = 0 then 'spring'
            when way_id in (          -- 2. Watercource with another name starts from the neighbouring segment
                select i2.way_id
                from tmp_ways_info_2 i1
                join tmp_ways_info_2 i2 
                    on i1.cnt_s_ends = 1
                        and i1.way_name <> ''
                        and i2.way_name <> ''
                        and i1.rel_id <> i2.rel_id
                        and i1.way_name <> i2.way_name
                        and i1.end_point_id = i2.start_point_id
                left join tmp_ways_info_2 i3 
                    on i3.way_id <> i1.way_id
                        and i1.end_point_id = i3.end_point_id
                        and (i2.way_name = i3.way_name or i2.rel_id = i3.rel_id)
                where i3.way_id is null
            )   then 'name_change'
            when way_id in (         -- 3. Side streams
                select distinct i2.way_id
                from tmp_ways_info_2 i1
                join lateral (
                    select i2.*
                    from tmp_ways_info_2 i2
                    where i2.start_point_id = i1.end_point_id
                        and i2.cnt_s_ends   > 0
                        and i2.cnt_s_starts > 1
                        and (i2.way_name = i1.way_name or i2.way_name = '' or coalesce(i2.rel_id, 0) = coalesce(i1.rel_id, 0))
                    order by coalesce(i2.rel_role, '') = 'main_stream' desc, i2.length_km desc
                    offset 1
                ) i2 on true
            ) then 'side_stream'
        end category
    from water.tmp_ways_info_2 i
    join water_ways w using(way_id)
)
select * from a where category is not null;
    
create index on tmp_starts(category);
create index on tmp_starts using gist(geom);

--      and way_id in (49023690, 645862054, 643464031, 1080226012, 1080226011, 645286195)
--  limit 40000
    )

    
    
    
        case 
            when  w1.cnt_e_ends <> 1 and w2.start_way_id is null then 1::int2
            when (w1.cnt_e_ends  = 1 and w1.cnt_e_starts = 0) and (w1.cnt_e_ends <> 1 and w2.start_way_id is not null and w1.length_km <= w2.length_km) then 2::int2
            when (w1.cnt_e_ends  = 1 and w1.cnt_e_starts > 0) and (w1.cnt_e_ends <> 1 and w2.start_way_id is not null and w1.length_km >  w2.length_km) then 0::int2
        end
    
    
    
        
        
        


----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
----------------------------------------------------
        
-- PART II


--show work_mem;
--set  work_mem to '512MB';

        
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
left join tmp_rels_info r using(way_id)
where   coalesce(tags ->> 'waterway', '') in ('river', 'canal');
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
    from built_waterways_1a_geom a
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