SET client_min_messages TO WARNING; 


------------------------------------------
--Proccess WikiData extract
------------------------------------------

-- First pass proccessing Wikidata dataset:
drop table if exists water.wikidata_tmp1 cascade;
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
drop table if exists water.wikidata_proccessed cascade;
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
drop table if exists water.wikidata_tmp1 cascade;





------------------------------------------
--Proccess OpenStreetMap extract
------------------------------------------

-- Create indexes
create index on water.water_relations(members);


-- Gather geometry from waterway relations
drop table if exists water.waterways_from_rels cascade;
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


-- Create separate table for waterways that are not in waterway relations
drop table if exists water.waterways_not_in_rels cascade;
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
drop table if exists water.waterways_from_rels2 cascade;
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
	


-- Create views for easier building Vector tiles using ogr2ogr
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



