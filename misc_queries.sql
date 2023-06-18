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
	select end_id id   from tmp_ways_info
)
select
	id,
	count(w1.*) cnt_starts,
	count(w2.*) cnt_ends
from ids i
left join tmp_ways_info w1 on w1.start_id = id
left join tmp_ways_info w2 on w2.end_id   = id
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
join tmp_points_info p1 
	on w.start_id = p1.id
join tmp_points_info p2 
	on w.end_id   = p2.id
where not (
		p1.cnt_starts = 1
	and p2.cnt_starts = 0
	and p1.cnt_ends = 0
	and p2.cnt_ends = 1
);

create index on tmp_ways_info2(way_id);
create index on tmp_ways_info2(rel_id);
create index on tmp_ways_info2(rel_role);
create index on tmp_ways_info2(way_type);
create index on tmp_ways_info2(way_name);
create index on tmp_ways_info2(start_id);
create index on tmp_ways_info2(end_id);
-- 10s


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
	join tmp_points_info s1 
		on s1.id = w.start_id
	where s1.cnt_ends > 1 
		or (s1.cnt_starts > 0 and s1.cnt_ends = 0)
	--
	union all
	--
	select 
		i + 1 i, 
		w2.way_id,
		w1.way_id_orig,
		w1.way_ids_arr || w2.way_id 									way_ids_arr,
		w2.start_id,
		w2.end_id,
		coalesce(nullif(w1.way_name, ''), nullif(w2.way_name, ''), '')	way_name,
		coalesce(w1.rel_id, w2.rel_id)									rel_id
	from waterway w1
	join tmp_points_info p 
		on w1.end_id = p.id
			and p.cnt_starts = 1
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
-- 5m 50s



drop table if exists water.tmp_built_waterways2;
create table water.tmp_built_waterways2 as
with recursive waterway as ((
	with ways_used as (
		select unnest(way_ids_arr) way_id from tmp_built_waterways1
	),
	ways_left as (
		select distinct 
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
		select start_id id
		from ways_left 
		union 
		select end_id id
		from ways_left
	),
	stat as (
		select id, count(w1.*) cnt_starts, count(w2.*) cnt_ends
		from ids i
		left join ways_left w1 on w1.start_id = id
		left join ways_left w2 on w2.end_id   = id
		group by id
	)
	select distinct
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
		w2.start_id,
		w2.end_id,
		coalesce(nullif(w1.way_name, ''), nullif(w2.way_name, ''), '')	way_name,
		coalesce(w1.rel_id, w2.rel_id)									rel_id
	from waterway w1
	join tmp_points_info p 
		on w1.end_id = p.id
			and p.cnt_starts = 1
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
-- 17s 


drop table if exists built_waterways;
create table built_waterways as
select 
	i.way_id way_id_orig,
	array[i.way_id] way_ids_arr,
	0 i,
	i.way_name,
	i.rel_id,
	array[i.rel_role] rel_roles_arr,
	i.length_km,
	g.geom
from tmp_ways_info i
left join water_ways		   g  using(way_id)
left join water.tmp_ways_info2 i2 using(way_id)
where i2.way_id is null
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
-- 1m 20s



-------------------------



drop table if exists built_waterways2;
create table built_waterways2 as
--select 
--	i.way_id way_id_orig,
--	array[i.way_id] way_ids_arr,
--	0 i,
--	i.way_name,
--	i.rel_id,
--	array[i.rel_role] rel_roles_arr,
--	i.length_km,
--	i.geom
--from water.tmp_ways_info i
--left join water.tmp_ways_info2 i2 using(way_id)
--where i2.way_id is null
----
--union all 
--
select 
	c.way_id_orig,
	c.way_ids_arr,
	c.i 												iterations,
	max(w.way_name) 									name,
	max(w.rel_id) filter(where w.rel_id is not null) 	rel_id,
	array_agg(distinct w.rel_role) filter(where w.rel_role is not null) 	rel_roles_arr,
	sum(length_km) 										length_km,
	st_linemerge(st_collect(w.geom) ,true)				geom
from (
	select * from tmp_built_waterways1 union all
	select * from tmp_built_waterways2
) c
left join tmp_ways_info w 
	on w.way_id = any(c.way_ids_arr)
group by c.way_id_orig,	c.way_ids_arr, c.i;
-- 30s

create index on built_waterways2 using gist(geom);

--select distinct rel_roles_arr from water.built_waterways2; !!!!!!!!!! {main_stream,side_stream} !!!!!!!!!!!!
--select st_geometrytype(geom), count(*) from water.built_waterways2 group by 1; --!!!!!!!!!! 'ST_MultiLineString' !!!!!!!!!!!!
select * from built_waterways where st_geometrytype(geom) = 'ST_MultiLineString'; --!!!!!!!!!! {main_stream,side_stream} !!!!!!!!!!!!


drop table if exists tmp_ways_info3;
create table tmp_ways_info3 as 
select 
	way_id_orig way_id,
	way_ids_arr,
	rel_id,
	"name" way_name,
--	rel_roles_arr,
	length_km,
		((round((st_x((st_startpoint(geom)))::numeric) * 100000) + 18000000)::text || (round((st_y((st_startpoint(geom)))::numeric) * 100000) + 18000000)::text)::int8 start_id,
		((round((st_x((  st_endpoint(geom)))::numeric) * 100000) + 18000000)::text || (round((st_y((  st_endpoint(geom)))::numeric) * 100000) + 18000000)::text)::int8 end_id,
	st_startpoint(geom) start_pnt,
	st_endpoint(geom) 	end_pnt,
	geom	
from built_waterways2;
-- 1m 30s

create index on tmp_ways_info3(way_id);
create index on tmp_ways_info3(rel_id);
--create index on tmp_ways_info2(rel_role);
--create index on tmp_ways_info2(way_type);
create index on tmp_ways_info3(length_km);
create index on tmp_ways_info3(way_name);
create index on tmp_ways_info3(start_id);
create index on tmp_ways_info3(end_id);
--create index on tmp_ways_info using gist(geom);
--create index on tmp_ways_info using gist(start_pnt);
--create index on tmp_ways_info using gist(end_pnt);
--15 s


drop table if exists tmp_points_info2;
create table tmp_points_info2 as 			
with ids as (
	select start_id id, start_pnt geom
	from tmp_ways_info3 
	union 
	select end_id id, end_pnt geom
	from tmp_ways_info3
)
select
	id,
	count(w1.*) cnt_starts,
	count(w2.*) cnt_ends,
	i.geom	
from ids i
left join tmp_ways_info3 w1 on w1.start_id = id
left join tmp_ways_info3 w2 on w2.end_id   = id
group by id, i.geom;

create index on tmp_points_info2(id);
create index on tmp_points_info2(cnt_starts, cnt_ends);
create index on tmp_points_info2 using gist(geom);
-- 25s




drop table if exists water.tmp_built_waterways3;
create table water.tmp_built_waterways3 as
with recursive waterway as (
	select 
		1 i, 
		w.way_id,
		w.way_id 		way_id_orig,
		way_ids_arr,
		w.start_id,
		w.end_id,
		w.way_name,
		w.rel_id
	from tmp_ways_info3 w
	join tmp_points_info2 s1 
		on s1.id = w.start_id
	where s1.cnt_starts > 0 
		and s1.cnt_ends = 0
	--
	union all
	--
	select 
		i + 1 i, 
		w2.way_id,
		w1.way_id_orig,
		w1.way_ids_arr || w2.way_id 									way_ids_arr,
		w2.start_id,
		w2.end_id,
		coalesce(nullif(w1.way_name, ''), nullif(w2.way_name, ''), '')	way_name,
		coalesce(w1.rel_id, w2.rel_id)									rel_id
	from waterway w1
--	join tmp_points_info2 p 
--		on w1.end_id = p.id
--			and p.cnt_starts = 1
	left join lateral (
		select w2.* 
		from tmp_ways_info3 w2
		where w2.start_id = w1.end_id
			and w2.way_id <> all(w1.way_ids_arr)
			and (coalesce(nullif(w2.way_name,''), w1.way_name) = coalesce(nullif(w1.way_name, ''), w2.way_name) -- check whether name is the same or blank
				or coalesce(w2.rel_id, w1.rel_id, 0) = coalesce(w1.rel_id, w2.rel_id, 0)						-- check whether relation_id is the same or null
			)
		order by w2.length_km desc
		limit 1
	) w2 on true
	where w2.way_id is not null
)
select distinct on(way_id_orig) * 
from waterway 
--where i > 1
order by way_id_orig, i desc;
-- 10s




drop table if exists built_waterways3;
create table built_waterways3 as
--select 
--	i.way_id way_id_orig,
--	array[i.way_id] way_ids_arr,
--	0 i,
--	i.way_name,
--	i.rel_id,
--	array[i.rel_role] rel_roles_arr,
--	i.length_km,
--	i.geom
--from water.tmp_ways_info i
--left join water.tmp_ways_info2 i2 using(way_id)
--where i2.way_id is null
----
--union all 
--
select 
	c.way_id_orig,
	c.way_ids_arr,
	c.i 												iterations,
	max(w.way_name) 									name,
	max(w.rel_id) filter(where w.rel_id is not null) 	rel_id,
--	array_agg(distinct w.rel_role) filter(where w.rel_role is not null) 	rel_roles_arr,
	sum(length_km) 										length_km,
	st_linemerge(st_collect(w.geom) ,true)				geom
from tmp_built_waterways3 c
left join tmp_ways_info3 w 
	on w.way_id = any(c.way_ids_arr)
group by c.way_id_orig,	c.way_ids_arr, c.i;
-- 2m

create index on built_waterways3 using gist(geom);



select distinct st_geometrytype(geom) from water.built_waterways;
select distinct st_geometrytype(geom) from water.tmp_ways_info;
select * from water.built_waterways where  st_geometrytype(geom) = 'ST_MultiLineString';
