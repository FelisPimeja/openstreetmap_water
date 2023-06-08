
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
select 
	w1.way_id,
	w1.geom
from water.water_ways w1
left join water.water_ways w2
	on w1.way_id <> w2.way_id
--		and w2.tags ->> 'waterway' in ('river', 'canal')
		and st_intersects(st_endpoint(w1.geom), w2.geom)
		and (st_endpoint(w1.geom) = st_startpoint(w2.geom)	
			or (    not st_equals(st_endpoint(w1.geom),   st_endpoint(w2.geom))
				and not st_equals(st_endpoint(w1.geom), st_startpoint(w2.geom))
			)
		)
left join water.water_ways w3
	on w1.way_id <> w3.way_id
--		and w3.tags ->> 'waterway' in ('river', 'canal')
		and st_intersects(st_endpoint(w1.geom), w3.geom)
		and st_endpoint(w1.geom) = st_endpoint(w3.geom)	
left join water.coast_lines c
	on st_intersects(st_endpoint(w1.geom), c.geom)
where true --w1.tags ->> 'waterway' in ('river', 'canal')
	and w2.way_id is null
	and w3.way_id is not null
	and c.way_id is null
union all 
select 
	w1.way_id,
	w1.geom
from water.water_ways w1
left join water.water_ways w2
	on w1.way_id <> w2.way_id
--		and w2.tags ->> 'waterway' in ('river', 'canal')
		and st_intersects(st_startpoint(w1.geom), w2.geom)
		and (st_startpoint(w1.geom) = st_endpoint(w2.geom)	
			or (    not st_equals(st_startpoint(w1.geom),   st_endpoint(w2.geom))
				and not st_equals(st_startpoint(w1.geom), st_startpoint(w2.geom))
			)
		)
left join water.water_ways w3
	on w1.way_id <> w3.way_id
--		and w3.tags ->> 'waterway' in ('river', 'canal')
		and st_intersects(st_startpoint(w1.geom), w3.geom)
		and st_startpoint(w1.geom) = st_startpoint(w3.geom)	
left join water.coast_lines c
	on st_intersects(st_startpoint(w1.geom), c.geom)
where true --w1.tags ->> 'waterway' in ('river', 'canal')
	and w2.way_id is null
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

