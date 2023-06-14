SET client_min_messages TO WARNING; 


------------------------------------------
-- Proccess WikiData extract
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
-- Proccess OpenStreetMap extract
------------------------------------------

-- Water areas
drop table if exists water.water_areas;
create table water.water_areas as 
select 
	area_id,
	coalesce(tags ->> 'water', tags ->> 'wetland', tags ->> 'natural') 	"type",
	tags ->> 'name' 													"name",
	tags,
	st_area(geom::geography)::int8 / 1000000 							area_sq_km,
	st_multi(geom)::geometry 											geom
from water.water_polygons;

create index on water.water_areas("type", area_sq_km);
create index on water.water_areas using gist(geom);



-- Create indexes
create index on water.water_relations(members);


-- Gather geometry from waterway relations
drop table if exists water.waterways_from_rels cascade;
create table water.waterways_from_rels as 
select 
	r.relation_id,
	r.tags ->> 'waterway' 						"type", 
	r.tags ->> 'name' 							"name", 
	r.tags ->> 'wikipedia' 						wikipedia, 
	r.tags ->> 'wikidata' 						wikidata, 
	r.tags ->> 'gvr:code'						gvr_code, 	
	r.tags,
	r.members,
	sum(st_length(geom::geography))::int / 1000 length_km, 
	st_linemerge(st_collect(w.geom), true) 		geom
from water.water_relations r
cross join jsonb_array_elements(members) m
left join water.water_ways w 
	on w.way_id = (m ->> 'ref')::int8
where m ->> 'type' = 'w'
	and r.tags ->> 'waterway' <> 'seaway'	 	-- Skip seaway routes
group by r.relation_id, r.tags, r.members;

create index on water.waterways_from_rels ("type", length_km);
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
select 
	w.way_id, 
	w.tags ->> 'waterway' 						"type", 
	w.tags ->> 'name' 							"name", 
	w.tags ->> 'wikipedia' 						wikipedia, 
	w.tags ->> 'wikidata' 						wikidata, 
	w.tags ->> 'gvr:code'						gvr_code, 
	st_length(w.geom::geography)::int / 1000 	length_km,
	w.geom
from water.water_ways w 
left join ways_in_rels r using(way_id)
where r.way_id is null
	and r.tags ->> 'waterway' <> 'seaway'; 	-- Skip seaway routes

create index on water.waterways_not_in_rels ("type", length_km);
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
	





------------------------------------------
-- Vector Tiles creation
------------------------------------------
-- Create views for easier building Vector tiles using ogr2ogr

drop view if exists water.lin_0;
create view water.lin_0 as 
select 
	'r' || relation_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.5) geom 
from water.waterways_from_rels
where "type" in ('river', 'canal') and length_km > 2000
union all 
select 
	'w' || way_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.5) geom 
from water.waterways_not_in_rels
where "type" in ('river', 'canal') and length_km > 2000;


drop view if exists water.lin_1;
create view water.lin_1 as 
select 
	'r' || relation_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.2) geom 
from water.waterways_from_rels
where "type" in ('river', 'canal') and length_km > 1000
union all 
select 
	'w' || way_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.2) geom 
from water.waterways_not_in_rels
where "type" in ('river', 'canal') and length_km > 1000;


drop view if exists water.lin_2;
create view water.lin_2 as 
select 
	'r' || relation_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.1) geom 
from water.waterways_from_rels
where "type" in ('river', 'canal') and length_km > 500
union all 
select 
	'w' || way_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.1) geom 
from water.waterways_not_in_rels
where "type" in ('river', 'canal') and length_km > 500;


drop view if exists water.lin_3;
create view water.lin_3 as 
select 
	'r' || relation_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.075) geom 
from water.waterways_from_rels
where "type" in ('river', 'canal') and length_km > 100
union all 
select 
	'w' || way_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.075) geom 
from water.waterways_not_in_rels
where "type" in ('river', 'canal') and length_km > 100;


drop view if exists water.lin_4;
create view water.lin_4 as 
select 
	'r' || relation_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.05) geom 
from water.waterways_from_rels
where "type" in ('river', 'canal') and length_km > 50
union all 
select 
	'w' || way_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.05) geom 
from water.waterways_not_in_rels
where "type" in ('river', 'canal') and length_km > 50;


drop view if exists water.lin_5;
create view water.lin_5 as 
select 
	'r' || relation_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.025) geom 
from water.waterways_from_rels
where length_km > 20
union all 
select 
	'w' || way_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.025) geom 
from water.waterways_not_in_rels
where length_km > 20;


drop view if exists water.lin_6;
create view water.lin_6 as 
select 
	'r' || relation_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.01) geom 
from water.waterways_from_rels
where length_km > 10
union all 
select 
	'w' || way_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.01) geom 
from water.waterways_not_in_rels
where length_km > 10;


drop view if exists water.lin_7;
create view water.lin_7 as 
select 
	'r' || relation_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.005) geom 
from water.waterways_from_rels
where length_km > 5
union all 
select 
	'w' || way_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.005) geom 
from water.waterways_not_in_rels
where length_km > 5;


drop view if exists water.lin_8;
create view water.lin_8 as 
select 
	'r' || relation_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.0025) geom 
from water.waterways_from_rels
where length_km > 2
union all 
select 
	'w' || way_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	st_simplify(geom, 0.0025) geom 
from water.waterways_not_in_rels
where length_km > 2;


drop view if exists water.lin_9;
create view water.lin_9 as 
select 
	'r' || relation_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	geom 
from water.waterways_from_rels
union all 
select 
	'w' || way_id::text id,
	"type", 
	"name", 
	wikipedia, 
	wikidata, 
	gvr_code,
	case
		when length_km > 2000 					then 'a'
		when length_km between 1000 and 2000 	then 'b'
		when length_km between  500 and 1000 	then 'c'
		when length_km between  100 and  500 	then 'd'
		when length_km between   50 and  100 	then 'e'
		when length_km between   20 and   50 	then 'f'
		when length_km between   10 and   20 	then 'g'
		when length_km between    5 and   10 	then 'h'
		when length_km between    2 and    5 	then 'i'
		when length_km < 2 						then 'j'
	end "class",
	geom 
from water.waterways_not_in_rels;




drop view if exists water.pol_0;
create view water.pol_0 as 
select 
	area_id id,
	case
		when "type" in ('river','canal','water','sea','lake','pond','oxbow','reservoir','wastewater','basin') then 'water'
		when "type" in ('wetland','marsh','bog','swamp','reedbed','wet_meadow','fen','tidalflat','saltmarsh') then 'wetland'
		else 'other'
	end "type",
	"name",
	case
		when area_sq_km > 1000 	then 'a'
		when area_sq_km >  500 	then 'b'
		when area_sq_km >  100 	then 'c'
		when area_sq_km >   50 	then 'd'
		when area_sq_km >   20 	then 'e'
		when area_sq_km >   10 	then 'f'
		when area_sq_km >    5 	then 'g'
		when area_sq_km >    2 	then 'h'
		else 						 'i'
	end "class",
	st_simplify(geom, 0.5) geom 
from water.water_areas
where area_sq_km > 1000;


drop view if exists water.pol_1;
create view water.pol_1 as 
select 
	area_id id,
	case
		when "type" in ('river','canal','water','sea','lake','pond','oxbow','reservoir','wastewater','basin') then 'water'
		when "type" in ('wetland','marsh','bog','swamp','reedbed','wet_meadow','fen','tidalflat','saltmarsh') then 'wetland'
		else 'other'
	end "type",
	"name",
	case
		when area_sq_km > 1000 	then 'a'
		when area_sq_km >  500 	then 'b'
		when area_sq_km >  100 	then 'c'
		when area_sq_km >   50 	then 'd'
		when area_sq_km >   20 	then 'e'
		when area_sq_km >   10 	then 'f'
		when area_sq_km >    5 	then 'g'
		when area_sq_km >    2 	then 'h'
		else 						 'i'
	end "class",
	st_simplify(geom, 0.2) geom 
from water.water_areas
where area_sq_km > 500;


drop view if exists water.pol_2;
create view water.pol_2 as 
select 
	area_id id,
	case
		when "type" in ('river','canal','water','sea','lake','pond','oxbow','reservoir','wastewater','basin') then 'water'
		when "type" in ('wetland','marsh','bog','swamp','reedbed','wet_meadow','fen','tidalflat','saltmarsh') then 'wetland'
		else 'other'
	end "type",
	"name",
	case
		when area_sq_km > 1000 	then 'a'
		when area_sq_km >  500 	then 'b'
		when area_sq_km >  100 	then 'c'
		when area_sq_km >   50 	then 'd'
		when area_sq_km >   20 	then 'e'
		when area_sq_km >   10 	then 'f'
		when area_sq_km >    5 	then 'g'
		when area_sq_km >    2 	then 'h'
		else 						 'i'
	end "class",
	st_simplify(geom, 0.1) geom 
from water.water_areas
where area_sq_km > 100;


drop view if exists water.pol_3;
create view water.pol_3 as 
select 
	area_id id,
	case
		when "type" in ('river','canal','water','sea','lake','pond','oxbow','reservoir','wastewater','basin') then 'water'
		when "type" in ('wetland','marsh','bog','swamp','reedbed','wet_meadow','fen','tidalflat','saltmarsh') then 'wetland'
		else 'other'
	end "type",
	"name",
	case
		when area_sq_km > 1000 	then 'a'
		when area_sq_km >  500 	then 'b'
		when area_sq_km >  100 	then 'c'
		when area_sq_km >   50 	then 'd'
		when area_sq_km >   20 	then 'e'
		when area_sq_km >   10 	then 'f'
		when area_sq_km >    5 	then 'g'
		when area_sq_km >    2 	then 'h'
		else 						 'i'
	end "class",
	st_simplify(geom, 0.075) geom 
from water.water_areas
where area_sq_km > 50;


drop view if exists water.pol_4;
create view water.pol_4 as 
select 
	area_id id,
	case
		when "type" in ('river','canal','water','sea','lake','pond','oxbow','reservoir','wastewater','basin') then 'water'
		when "type" in ('wetland','marsh','bog','swamp','reedbed','wet_meadow','fen','tidalflat','saltmarsh') then 'wetland'
		else 'other'
	end "type",
	"name",
	case
		when area_sq_km > 1000 	then 'a'
		when area_sq_km >  500 	then 'b'
		when area_sq_km >  100 	then 'c'
		when area_sq_km >   50 	then 'd'
		when area_sq_km >   20 	then 'e'
		when area_sq_km >   10 	then 'f'
		when area_sq_km >    5 	then 'g'
		when area_sq_km >    2 	then 'h'
		else 						 'i'
	end "class",
	st_simplify(geom, 0.05) geom 
from water.water_areas
where area_sq_km > 20;


drop view if exists water.pol_5;
create view water.pol_5 as 
select 
	area_id id,
	case
		when "type" in ('river','canal','water','sea','lake','pond','oxbow','reservoir','wastewater','basin') then 'water'
		when "type" in ('wetland','marsh','bog','swamp','reedbed','wet_meadow','fen','tidalflat','saltmarsh') then 'wetland'
		else 'other'
	end "type",
	"name",
	case
		when area_sq_km > 1000 	then 'a'
		when area_sq_km >  500 	then 'b'
		when area_sq_km >  100 	then 'c'
		when area_sq_km >   50 	then 'd'
		when area_sq_km >   20 	then 'e'
		when area_sq_km >   10 	then 'f'
		when area_sq_km >    5 	then 'g'
		when area_sq_km >    2 	then 'h'
		else 						 'i'
	end "class",
	st_simplify(geom, 0.025) geom 
from water.water_areas
where area_sq_km > 10;


drop view if exists water.pol_6;
create view water.pol_6 as 
select 
	area_id id,
	case
		when "type" in ('river','canal','water','sea','lake','pond','oxbow','reservoir','wastewater','basin') then 'water'
		when "type" in ('wetland','marsh','bog','swamp','reedbed','wet_meadow','fen','tidalflat','saltmarsh') then 'wetland'
		else 'other'
	end "type",
	"name",
	case
		when area_sq_km > 1000 	then 'a'
		when area_sq_km >  500 	then 'b'
		when area_sq_km >  100 	then 'c'
		when area_sq_km >   50 	then 'd'
		when area_sq_km >   20 	then 'e'
		when area_sq_km >   10 	then 'f'
		when area_sq_km >    5 	then 'g'
		when area_sq_km >    2 	then 'h'
		else 						 'i'
	end "class",
	st_simplify(geom, 0.01) geom 
from water.water_areas
where area_sq_km > 5;


drop view if exists water.pol_7;
create view water.pol_7 as 
select 
	area_id id,
	case
		when "type" in ('river','canal','water','sea','lake','pond','oxbow','reservoir','wastewater','basin') then 'water'
		when "type" in ('wetland','marsh','bog','swamp','reedbed','wet_meadow','fen','tidalflat','saltmarsh') then 'wetland'
		else 'other'
	end "type",
	"name",
	case
		when area_sq_km > 1000 	then 'a'
		when area_sq_km >  500 	then 'b'
		when area_sq_km >  100 	then 'c'
		when area_sq_km >   50 	then 'd'
		when area_sq_km >   20 	then 'e'
		when area_sq_km >   10 	then 'f'
		when area_sq_km >    5 	then 'g'
		when area_sq_km >    2 	then 'h'
		else 						 'i'
	end "class",
	st_simplify(geom, 0.005) geom 
from water.water_areas
where area_sq_km > 2;


drop view if exists water.pol_8;
create view water.pol_8 as 
select 
	area_id id,
	case
		when "type" in ('river','canal','water','sea','lake','pond','oxbow','reservoir','wastewater','basin') then 'water'
		when "type" in ('wetland','marsh','bog','swamp','reedbed','wet_meadow','fen','tidalflat','saltmarsh') then 'wetland'
		else 'other'
	end "type",
	"name",
	case
		when area_sq_km > 1000 	then 'a'
		when area_sq_km >  500 	then 'b'
		when area_sq_km >  100 	then 'c'
		when area_sq_km >   50 	then 'd'
		when area_sq_km >   20 	then 'e'
		when area_sq_km >   10 	then 'f'
		when area_sq_km >    5 	then 'g'
		when area_sq_km >    2 	then 'h'
		else 						 'i'
	end "class",
	st_simplify(geom, 0.0025) geom 
from water.water_areas;


drop view if exists water.pol_9;
create view water.pol_9 as 
select 
	area_id id,
	case
		when "type" in ('river','canal','water','sea','lake','pond','oxbow','reservoir','wastewater','basin') then 'water'
		when "type" in ('wetland','marsh','bog','swamp','reedbed','wet_meadow','fen','tidalflat','saltmarsh') then 'wetland'
		else 'other'
	end "type",
	"name",
	case
		when area_sq_km > 1000 	then 'a'
		when area_sq_km >  500 	then 'b'
		when area_sq_km >  100 	then 'c'
		when area_sq_km >   50 	then 'd'
		when area_sq_km >   20 	then 'e'
		when area_sq_km >   10 	then 'f'
		when area_sq_km >    5 	then 'g'
		when area_sq_km >    2 	then 'h'
		else 						 'i'
	end "class",
	geom 
from water.water_areas;




