
-- Брошенные концы водотоков:
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



-- Сборка геометрии водотоков с минимальными негативными эффектами
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



-- Рекурсивная сборка водотоков
-- Уходит в бесконечный цикл и вываливается по памяти если сталкивается с закольцованным маршрутом!!!
-- 2m 18s на ЦФО
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

-- Удаление закольцовывающего дубликата:
delete from water.water_ways where way_id  = 677306284;


select 'Water ways (river) segments count'      category, count(*) from water.water_ways where tags ->> 'waterway' = 'river' union all
select 'Water ways after recursive merge count' category, count(*) from water.a5;






-- Сборка и приведение данных из Викидаты:
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



-- Пересборка приблизительной геометрии реки с учётом устей притоков:
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
					array_append(
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


create index on water.wikidata_proccessed(id);
create index on water.wikidata_proccessed(mouthq_id);
create index on water.wikidata_proccessed(tributary_id_list);
create index on water.wikidata_proccessed(gvr_id);
create index on water.wikidata_proccessed using gist(source_pnt);
create index on water.wikidata_proccessed using gist(mouth_pnt);
create index on water.wikidata_proccessed using gist(geom);


drop table if exists water.wikidata_tmp1;



