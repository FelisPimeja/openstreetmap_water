-- Run with: psql ... -v schema=YOUR_SCHEMA_NAME -f proccess_data.sql
-- (schema must already exist and contain osm_points/osm_ways/osm_areas/osm_relations from water.lua import)
SET client_min_messages TO WARNING;


------------------------------------------
-- Proccess WikiData extract
------------------------------------------

-- First pass proccessing Wikidata dataset:
drop table if exists :schema.tmp_wikidata_waterways_ru cascade;
create table :schema.tmp_wikidata_waterways_ru as
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
from :schema.raw_wikidata_waterways_ru;
create index on :schema.tmp_wikidata_waterways_ru(id);



-- Build very simple waterway geometry from start, end points and tributary mouth points (if any):
drop table if exists :schema.fin_wikidata_waterways_ru cascade;
create table :schema.fin_wikidata_waterways_ru as 
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
from :schema.tmp_wikidata_waterways_ru w1
left join :schema.tmp_wikidata_waterways_ru w2 
	on w2.id = any(w1.tributary_id_list)
group by 
	w1.id, w1.name_ru, w1.tributary_id_list, 
	w1.source_pnt, w1.mouth_pnt, w1.geom,
	w1.name_en, w1.mouthq_id, w1.length_km,
	w1.gvr_id, w1.osm_id;

-- Create indexes 
create index on :schema.fin_wikidata_waterways_ru(id);
create index on :schema.fin_wikidata_waterways_ru(mouthq_id);
create index on :schema.fin_wikidata_waterways_ru(tributary_id_list);
create index on :schema.fin_wikidata_waterways_ru(gvr_id);
create index on :schema.fin_wikidata_waterways_ru using gist(source_pnt);
create index on :schema.fin_wikidata_waterways_ru using gist(mouth_pnt);
create index on :schema.fin_wikidata_waterways_ru using gist(geom);

-- Drop temporary tables
--drop table if exists :schema.tmp_wikidata_waterways_ru cascade;





------------------------------------------
-- Proccess OpenStreetMap extract
------------------------------------------

    
    
-- create index start_point_idx on :schema.osm_ways((nodes[1]));
-- create index end_point_idx on :schema.osm_ways((nodes[cardinality(nodes)]));
-- create index on :schema.osm_areas(way_osm_id);


drop table if exists :schema.contours;
create table :schema.contours as
select way_osm_id, tags, st_subdivide(st_boundary(geom)) geom
from :schema.osm_areas
where tags ->> 'natural' = 'water';

-- st_boundary/st_subdivide return untyped geometry; constrain for QGIS (single-type layers).
alter table :schema.contours alter column geom type geometry(LineString,4326) using st_setsrid(geom,4326);

create index on  :schema.contours (way_osm_id);
create index on  :schema.contours using gist(geom);


drop table if exists :schema.graph_nodes;
create table :schema.graph_nodes as 
select distinct * from (
    select nodes[1] pnt_osm_id, st_startpoint(geom) geom
    from :schema.osm_ways
    where tags ->> 'waterway' in ('river', 'stream', 'canal', 'drain', 'ditch', 'flowline')
    union all
    select nodes[cardinality(nodes)] pnt_osm_id, st_endpoint(geom) geom
    from :schema.osm_ways
    where tags ->> 'waterway' in ('river', 'stream', 'canal', 'drain', 'ditch', 'flowline')
) a;

alter table :schema.graph_nodes alter column geom type geometry(Point,4326) using st_setsrid(geom,4326);

create index on :schema.graph_nodes(pnt_osm_id);
create index on :schema.graph_nodes using gist(geom);



drop table if exists :schema.graph_nodes_stat;
create table :schema.graph_nodes_stat as 
select 
    gn.pnt_osm_id,
    ww.way_osm_id,
    case
        when gn.pnt_osm_id = ww.nodes[1]                    then 'str'
        when gn.pnt_osm_id = ww.nodes[cardinality(nodes)]   then 'end'
        else 'mid'
    end type
from :schema.graph_nodes gn
join :schema.osm_ways ww 
    on st_intersects(gn.geom, ww.geom)
        and ww.tags ->> 'waterway' in ('river', 'stream', 'canal', 'drain', 'ditch', 'flowline')
union all
select 
    gn.pnt_osm_id,
    ww.way_osm_id,
    case 
        when ww.tags ->> 'natural' = 'coastline' then 'cst' 
        else 'dam'
    end type
from :schema.graph_nodes gn
join :schema.osm_ways ww 
    on st_intersects(gn.geom, ww.geom)
        and (   ww.tags ->> 'natural' = 'coastline'
            or  ww.tags ->> 'waterway' in ('dam', 'weir')
        )
union all    
select 
    gn.pnt_osm_id,
    wc.way_osm_id,
    'bnk' type
from :schema.graph_nodes gn
join :schema.contours wc 
    on st_intersects(gn.geom, wc.geom);

create index on :schema.graph_nodes_stat(pnt_osm_id, type);
create index on :schema.graph_nodes_stat(way_osm_id);
create index on :schema.graph_nodes_stat(type);



drop table if exists :schema.graph_nodes_stat_agg; 
create table :schema.graph_nodes_stat_agg as 
select 
    pnt_osm_id, 
    count(*) filter(where type = 'str')  str,
    count(*) filter(where type = 'mid')  mid,
    count(*) filter(where type = 'end') "end",
    count(*) filter(where type = 'bnk')  bnk,
    count(*) filter(where type = 'cst')  cst,
    count(*) filter(where type = 'dam')  dam
from :schema.graph_nodes_stat
    group by pnt_osm_id;

--create index on :schema.graph_nodes_stat2(pnt_osm_id);
create index on :schema.graph_nodes_stat_agg(str, mid, "end", bnk, cst, dam, pnt_osm_id);
create index on :schema.graph_nodes_stat_agg(pnt_osm_id, str, mid, "end", bnk, cst, dam);





-- Check for duplicated ways:
drop table if exists :schema.err_duplicated_ways cascade;
create table :schema.err_duplicated_ways as
with dups as (
    select geom 
    from :schema.osm_ways
    where tags ? 'waterway'
    group by geom
    having count(*) > 1
)
select ww.* 
from :schema.osm_ways ww
join dups using(geom);

create index err_duplicated_ways_geom_idx on :schema.err_duplicated_ways using gist(geom);



-- Check for duplicated areas:
drop table if exists :schema.err_duplicated_areas cascade;
create table :schema.err_duplicated_areas as 
with dups as (
    select geom 
    from :schema.osm_areas
    where tags ->> 'natural' in ('water', 'wetland')
    group by geom
    having count(*) > 1
)
select wa.* 
from :schema.osm_areas wa
join dups using(geom);

create index err_duplicated_areas_geom_idx on :schema.err_duplicated_areas using gist(geom);


-- Check for overlapping waterways (excluding full duplicates):
drop table if exists :schema.err_overlapping_ways cascade;
create table :schema.err_overlapping_ways as 
select 
    array[w1.way_osm_id, w2.way_osm_id] osm_ids,
    st_collectionextract(st_intersection(w1.geom, w2.geom), 2) geom
from :schema.osm_ways w1
join :schema.osm_ways w2
    on w1.way_osm_id > w2.way_osm_id
        and st_overlaps(w1.geom, w2.geom)
        and not st_equals(w1.geom, w2.geom)
        and w2.tags ? 'waterway'
where w1.tags ? 'waterway';

-- st_collectionextract(...,2) can return LineString or MultiLineString depending on the
-- overlap topology (single vs. multiple disjoint segments) — normalize to Multi for QGIS.
alter table :schema.err_overlapping_ways alter column geom type geometry(MultiLineString,4326) using st_setsrid(st_multi(geom),4326);

create index err_overlapping_ways_geom_idx on :schema.err_overlapping_ways using gist(geom);





-- Unconnected to network, connected to waterways:
drop table if exists :schema.err_unconnected_to_network;
create table :schema.err_unconnected_to_network as
select ww.way_osm_id, ww.tags, ww.geom 
from :schema.graph_nodes_stat_agg sa
join :schema.osm_ways ww
    on ww.nodes[cardinality(nodes)] = sa.pnt_osm_id
        and ww.tags ->> 'waterway' ~ 'river|stream|canal|drain|ditch|flowline'
where   sa.str = 0
    and sa.mid = 0
    and sa.cst = 0
    and sa.bnk > 0;

create index on :schema.err_unconnected_to_network using gist(geom);




-- Waterways with possible wrong directions:
drop table if exists :schema.err_possible_wrong_dir cascade;
create table :schema.err_possible_wrong_dir as
select ww.way_osm_id, ww.tags, ww.geom 
from :schema.osm_ways ww
left join :schema.graph_nodes_stat_agg ws
    on ww.nodes[1] = ws.pnt_osm_id
left join :schema.graph_nodes_stat_agg we
    on ww.nodes[cardinality(nodes)] = we.pnt_osm_id
where ww.tags ->> 'waterway' ~ 'river|stream|canal|drain|ditch|flowline'
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

create index on :schema.err_possible_wrong_dir using gist(geom);





-- Связка через центр водоёма между уже существующими входом и выходом (в отличие от
-- err_possible_isolated_water_areas выше — тут не ищем ничего по расстоянию, оба конца уже
-- топологически касаются берега). Это ровно случай waterway=flowline из де-факто OSM-конвенции
-- (см. комментарий у err_possible_isolated_water_areas выше, там же ссылки на вики) — предложение
-- этой таблицы буквально "проведите waterway=flowline здесь".
drop table if exists :schema.err_possible_missing_segments;
create table :schema.err_possible_missing_segments as
with water_points as (
    select 
        ns.way_osm_id waterarea_osm_id, 
        sa.pnt_osm_id, sa.str, sa.end, sa.bnk
    from :schema.graph_nodes_stat     ns
    join :schema.graph_nodes_stat_agg sa
        on ns.pnt_osm_id = sa.pnt_osm_id
            and sa.bnk > 0
            and sa.cst = 0
            and (   (sa.str > 0 and sa.end = 0)
                or  (sa.end > 0 and sa.str = 0)
            )
    join :schema.osm_areas wa 
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
    left join :schema.osm_areas wa 
        on wa.way_osm_id = wp.waterarea_osm_id
),
water_out as (
    select 
        wp.waterarea_osm_id, 
        ww.way_osm_id, 
        ww.tags, 
        st_startpoint(ww.geom) geom
    from water_points wp 
    join :schema.osm_ways ww 
        on ww.nodes[1] = wp.pnt_osm_id
            and ww.tags ->> 'waterway' in ('river','stream','canal','drain','ditch','flowline')
),
water_in as (
    select 
        wp.waterarea_osm_id, 
        ww.way_osm_id, 
        ww.tags, 
        st_endpoint(ww.geom) geom 
    from water_points wp 
    join :schema.osm_ways ww 
        on ww.nodes[cardinality(nodes)] = wp.pnt_osm_id
            and ww.tags ->> 'waterway' in ('river','stream','canal','drain','ditch','flowline')
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

alter table :schema.err_possible_missing_segments alter column geom type geometry(LineString,4326) using st_setsrid(geom,4326);

create index on :schema.err_possible_missing_segments using gist(geom);






drop table if exists :schema.err_possible_missing_segments2; 
create table :schema.err_possible_missing_segments2 as 
with unconnected as (
    select ww.way_osm_id, ww.tags, ww.geom, sa.pnt_osm_id
    from :schema.graph_nodes_stat_agg sa
    join :schema.osm_ways ww
        on ww.nodes[cardinality(nodes)] = sa.pnt_osm_id
            and ww.tags ->> 'waterway' ~ 'river|stream|canal|drain|ditch|flowline'
    where   sa.str = 0
        and sa.mid = 0
        and sa.cst = 0
        and sa.bnk > 0
),
water_banks as (
    select pnt_osm_id
    from unconnected uc
    join :schema.graph_nodes_stat ns using(pnt_osm_id)
    join :schema.osm_areas wa 
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
left join :schema.err_possible_missing_segments ms 
    on ms.in_osm_id = un.way_osm_id
join lateral (
    select 
        ww.way_osm_id,
        ww.tags,
        ww.geom
    from :schema.osm_ways ww
    where ww.way_osm_id <> un.way_osm_id
        and ww.tags ->> 'waterway' in ('river','canal','flowline'/*,'stream','drain','ditch'*/)
        and not st_intersects(un.geom, ww.geom)
        and not ww.tags ? 'tunnel'
    order by ww.geom <-> st_endpoint(un.geom)
    limit 1
) wn on true
where ms.in_osm_id is null;
--    and un.tags ->> 'water' = 'river';

alter table :schema.err_possible_missing_segments2 alter column geom type geometry(LineString,4326) using st_setsrid(geom,4326);

create index on :schema.err_possible_missing_segments2 using gist(geom);




-- Водоёмы (natural=water), не пересекающиеся ни с одним водотоком — кандидаты на "оторванный"
-- исток/устье. Единица анализа — связная компонента близко расположенных изолированных
-- водоёмов ("каскад прудов"), а не каждый водоём по отдельности: на полном прогоне по России
-- 67.7% изолированных водоёмов (выборка) имеют другой изолированный водоём в пределах тех же
-- 300м — если искать связку только с водотоком по отдельности для каждого пруда, получаем либо
-- пропуск (нет кандидата рядом — молчаливо не попадает в отчёт), либо неверный далёкий коннектор
-- вместо близкого пруда-соседа, который на самом деле часть того же каскада.
--
-- Компоненты размером >10 — молча исключаются из проверки целиком (не попадают ни в одну из
-- таблиц ниже, ни в err_all). Это не каскад, а плотное природное озёрное поле (термокарст/пойма —
-- Зап. Сибирь, Чукотка, низовья Кубани, бассейн Амура), для которого "нет выхода к сети" не
-- диагноз, а факт ландшафта; к ним планируется вернуться отдельно. Решение и порог — см.
-- CLAUDE.md.
--
-- Направление (исток/устье) берётся из направления линии водотока (nodes[1] = исток,
-- nodes[last] = устье) на границе компоненты — то же допущение, которое иногда неверно в
-- err_possible_wrong_dir; внутренний порядок каскада (какой пруд выше по течению) принципиально
-- не определим по геометрии и не должен угадываться — направление нужно знать только там, где
-- компонента реально касается настоящего водотока.
--
-- err_possible_isolated_water_areas (коннектор к сети найден) и err_isolated_water_clusters
-- (компонента 2-10 без единого кандидата) — сами по себе advisory, но участники (все члены
-- cluster_members, не только anchor-пруд) дополнительно получают err_id ('7-1'/'7-2'/'7-3') в
-- err_all — см. блок err_all ниже.
--
-- Конкретное предложение по исправлению для err_possible_isolated_water_areas — это конкретный
-- тег: провести waterway=flowline от найденного коннектора (де-факто конвенция OSM с 2024г. для
-- водотока, проходящего через озеро/водоём без различимого русла — см. Tag:waterway=flowline
-- https://wiki.openstreetmap.org/wiki/Tag:waterway=flowline и черновое предложение
-- Proposal:Flowlines https://wiki.openstreetmap.org/wiki/Proposal:Flowlines, статус "Proposed"/RFC
-- с 2024, детали вроде наследования name и порога размера водоёма оставлены на усмотрение
-- локальных сообществ). 'flowline' уже добавлен в фильтры связности по всему файлу (graph_nodes,
-- err_unconnected_to_network, err_possible_wrong_dir, err_possible_missing_segments/2 и ниже) —
-- водоёмы, уже корректно связанные через существующий flowline (897 таких way в данных на
-- 2026-08-03), больше не считаются изолированными.

-- Материализуем начала/концы линий отдельными индексированными таблицами, а не CTE — тот же
-- урок, что и с tmp_err_types_ways выше: KNN-сортировка (`<->`) по вычисленному
-- st_startpoint/st_endpoint без собственного индекса на большом числе строк дала 266.7с на
-- err_types при 4105 строках; здесь потенциально 1.3М+ ways по всей России.
-- Отдельно нужна проекция geom_3857: ST_ClosestPoint и KNN-сортировка в сырых градусах (4326)
-- дают неверный "ближайший" узел на высоких широтах (градус долготы физически короче градуса
-- широты в разы — на 73°с.ш. почти в 3.4x), из-за чего коннектор может указать на узел
-- за пределами реального порога расстояния. Обнаружено эмпирически на полном прогоне по России
-- (Таймыр/Ямал/Чукотка) — без проекции расстояние в части случаев доходило до 500-600м при
-- заданном пороге 300м. Порог по расстоянию (`st_dwithin`) при этом считается честно в
-- geography (не подвержено этому искажению) — 3857 нужна только для выбора конкретной точки/
-- кандидата, не для порога.
--
-- Важно: точка start/endway должна быть НАСТОЯЩИМ тупиком сети, а не местом разреза линии в OSM
-- (длинный водоток обычно мапится несколькими последовательными way — конец одного ровно там же,
-- где начало следующего). Джойним на уже посчитанный graph_nodes_stat_agg (см. выше) и требуем,
-- чтобы в этой точке был ровно один участник (сам этот way, тип str для начала / end для конца) —
-- иначе легко получить пару "пруд→канава" и "канава→пруд" для одного и того же way, если канава
-- продолжается дальше другим way у самого этого узла (найдено эмпирически: 96428530→885536329 —
-- 885536329 длиной 25.6м, его конец имел str=1 в graph_nodes_stat_agg, т.е. ровно там начинается
-- продолжение той же канавы другим way; без этого фильтра — 40.5% "начал" и 85% "концов" по всей
-- России оказываются такими же точками разреза, а не настоящими тупиками).
drop table if exists :schema.tmp_way_starts;
create table :schema.tmp_way_starts as
select ww.way_osm_id, st_startpoint(ww.geom) geom, st_transform(st_startpoint(ww.geom), 3857) geom_3857
from :schema.osm_ways ww
join :schema.graph_nodes_stat_agg sa on sa.pnt_osm_id = ww.nodes[1]
where ww.tags ->> 'waterway' ~ 'river|stream|canal|drain|ditch|flowline'
    and not ww.tags ? 'tunnel'
    and sa.str = 1 and sa."end" = 0 and sa.mid = 0;

create index on :schema.tmp_way_starts using gist(geom_3857);

-- bnk несём с собой (не фильтруем тут) — нужен ниже в err_possible_waterway_gaps, чтобы отсечь
-- водотоки, уже доведённые до площадного водоёма и там брошенные: для них связность уже решена
-- через err_unconnected_to_network/err_possible_missing_segments (flowline-предложение), не нужно
-- ЕЩЁ и предлагать связку с посторонним водотоком — задваивание. Для err_possible_isolated_water_areas
-- (inflow-поиск) bnk не фильтруем — там водоём, к которому уже что-то касается, и так не попадёт
-- в tmp_unconnected_areas (см. её собственный not exists), так что фильтр там не нужен.
drop table if exists :schema.tmp_way_ends;
create table :schema.tmp_way_ends as
select ww.way_osm_id, st_endpoint(ww.geom) geom, st_transform(st_endpoint(ww.geom), 3857) geom_3857,
       sa.bnk
from :schema.osm_ways ww
join :schema.graph_nodes_stat_agg sa on sa.pnt_osm_id = ww.nodes[cardinality(ww.nodes)]
where ww.tags ->> 'waterway' ~ 'river|stream|canal|drain|ditch|flowline'
    and not ww.tags ? 'tunnel'
    and sa."end" = 1 and sa.str = 0 and sa.mid = 0;

create index on :schema.tmp_way_ends using gist(geom_3857);

drop table if exists :schema.tmp_unconnected_areas;
create table :schema.tmp_unconnected_areas as
select wa.way_osm_id, wa.geom, st_transform(wa.geom, 3857) geom_3857,
       -- упрощённая геометрия для pond-pond honest-distance джойна ниже: полный geom некоторых
       -- полигонов доходит до 34670 вершин, st_dwithin(geography) на них — 62.9с/20000 строк;
       -- на geom_simple (допуск 0.0002°, ~22м — на порядок точнее нашего 300м порога) — 8.4с.
       st_multi(st_simplifypreservetopology(wa.geom, 0.0002)) geom_simple
from :schema.osm_areas wa
where wa.tags @> '{"natural":"water"}'
    and not exists (
        select 1
        from :schema.osm_ways ww
        where ww.tags ->> 'waterway' ~ 'river|stream|canal|drain|ditch|flowline'
            and st_intersects(ww.geom, wa.geom)
    );

create index on :schema.tmp_unconnected_areas using gist(geom);
create index on :schema.tmp_unconnected_areas using gist(geom_3857);
create unique index on :schema.tmp_unconnected_areas(way_osm_id);
analyze :schema.tmp_unconnected_areas;

-- Честные pond-pond рёбра (geography, не проекция — здесь ошибка выбора компоненты весит
-- гораздо больше, чем ошибка выбора конкретной точки, которую чинили выше через 3857).
drop table if exists :schema.tmp_pond_edges;
create table :schema.tmp_pond_edges as
select a.way_osm_id a_id, b.way_osm_id b_id
from :schema.tmp_unconnected_areas a
join :schema.tmp_unconnected_areas b
    on b.way_osm_id <> a.way_osm_id
    and b.geom_3857 && st_expand(a.geom_3857, 3000)
    and st_dwithin(a.geom_simple::geography, b.geom_simple::geography, 300)
where a.way_osm_id < b.way_osm_id;

create index on :schema.tmp_pond_edges(a_id);
create index on :schema.tmp_pond_edges(b_id);

-- Связные компоненты через min-label propagation (только для водоёмов, у которых есть хотя бы
-- одно ребро — синглтоны без соседей не нуждаются в итерации). Итерируем до ПОЛНОЙ сходимости
-- на неизменном графе — НЕ удаляя узлы/рёбра компонент, уже превысивших 10 участников, в
-- процессе: попытка "рано" исключать такие узлы (экономии ради) обрывает связность для ДРУГИХ
-- узлов, которые ещё не успели домержиться через них, и часть истинно больших компонент
-- ошибочно разваливается на "большую" + "ложно маленькую" (проверено эмпирически: давало
-- 354539/306592 узлов "исключено" вместо честных 369537 — граница определялась порядком
-- итераций, а не топологией графа). Классифицируем по размеру только после полной сходимости.
drop table if exists :schema.tmp_cluster_labels;
create table :schema.tmp_cluster_labels as
select x way_osm_id, x label
from (select a_id x from :schema.tmp_pond_edges union select b_id from :schema.tmp_pond_edges) t;

create unique index on :schema.tmp_cluster_labels(way_osm_id);
create index on :schema.tmp_cluster_labels(label);

drop table if exists :schema.tmp_edges_sym;
create table :schema.tmp_edges_sym as
select a_id node, b_id neighbor from :schema.tmp_pond_edges
union all
select b_id node, a_id neighbor from :schema.tmp_pond_edges;

create index on :schema.tmp_edges_sym(node);

-- psql не подставляет :schema внутри dollar-quoted тела DO-блока — пробрасываем значение через
-- GUC, подставляя :schema только в обычном (не dollar-quoted) SQL-тексте снаружи.
select set_config('opw.schema', :'schema', false);

do $$
declare
    v_schema text := current_setting('opw.schema');
    v_updated bigint;
    v_iter int := 0;
begin
    loop
        v_iter := v_iter + 1;
        exit when v_iter > 1000; -- защитный потолок, в норме сходится за десятки итераций

        execute format($f$
            update %1$I.tmp_cluster_labels cl
            set label = sub.min_label
            from (
                select e.node, min(nb.label) min_label
                from %1$I.tmp_edges_sym e
                join %1$I.tmp_cluster_labels nb on nb.way_osm_id = e.neighbor
                group by e.node
            ) sub
            where cl.way_osm_id = sub.node
                and sub.min_label < cl.label
        $f$, v_schema);
        get diagnostics v_updated = row_count;

        exit when v_updated = 0;
    end loop;

    raise notice 'err_possible_isolated_water_areas: connected components converged after % iterations', v_iter;
end
$$;

-- Итоговая принадлежность: синглтоны (никогда не имели ребра) + компоненты размером ≤10.
-- Компоненты >10 — молча исключены (не участвуют ни в одной из последующих таблиц).
drop table if exists :schema.tmp_final_clusters;
create table :schema.tmp_final_clusters as
select way_osm_id, label as cluster_id, cnt as cluster_size
from (
    select way_osm_id, label, count(*) over (partition by label) cnt
    from :schema.tmp_cluster_labels
) sub
where cnt <= 10
union all
select way_osm_id, way_osm_id as cluster_id, 1 as cluster_size
from :schema.tmp_unconnected_areas
where way_osm_id not in (select way_osm_id from :schema.tmp_cluster_labels);

create unique index on :schema.tmp_final_clusters(way_osm_id);
create index on :schema.tmp_final_clusters(cluster_id);

drop table if exists :schema.tmp_cluster_members;
create table :schema.tmp_cluster_members as
select cluster_id, cluster_size, array_agg(way_osm_id order by way_osm_id) members
from :schema.tmp_final_clusters
group by cluster_id, cluster_size;

create unique index on :schema.tmp_cluster_members(cluster_id);

-- Материализуем сами линии водотоков (упрощённая геометрия + 3857, тот же приём, что и для
-- pond-pond рёбер выше) — нужны ниже, чтобы проверить конкурирующий водоток у каждого тупика.
drop table if exists :schema.tmp_waterway_lines;
create table :schema.tmp_waterway_lines as
select way_osm_id,
       st_transform(geom, 3857) geom_3857,
       st_simplifypreservetopology(geom, 0.0002) geom_simple
from :schema.osm_ways
where tags ->> 'waterway' ~ 'river|stream|canal|drain|ditch|flowline'
    and not tags ? 'tunnel';

create index on :schema.tmp_waterway_lines using gist(geom_3857);

-- Кандидаты outflow/inflow — поиск ОТ тупика, а не от пруда: для каждого настоящего тупика
-- (tmp_way_starts/tmp_way_ends) ищем ближайший изолированный водоём, и берём его только если
-- РЯДОМ НЕТ ДРУГОГО ВОДОТОКА БЛИЖЕ, чем найденный пруд. Иначе тупик, скорее всего, на самом деле
-- относится к разрыву сети водотоков (пропуск в мапинге OSM — snap не случился), а не к дренажу
-- нашего пруда, и его не стоит красть под пруд.
--
-- Найдено эмпирически (2026-08-03, кейс от пользователя): пруд 96428530 получил связку на
-- тупик 885536333 (261м), хотя тот же тупик находится всего в 33.6м от ДРУГОГО водотока
-- 885536336 — то есть на самом деле это разрыв сети, а не сброс пруда. Поиск "от пруда к
-- ближайшему тупику" не может это обнаружить, т.к. смотрит только на дистанцию до своего же
-- пруда; поиск "от тупика" сравнивает оба варианта сразу и естественным образом выбирает
-- ближайший — без отдельной постфильтрации.
drop table if exists :schema.tmp_pond_candidates;
create table :schema.tmp_pond_candidates as
select
    pond.way_osm_id  wa_osm_id,
    fc.cluster_id,
    fc.cluster_size,
    'outflow'        direction,
    ts.way_osm_id,
    st_transform(st_makeline(st_closestpoint(pua.geom_3857, ts.geom_3857), ts.geom_3857), 4326) geom,
    pond.dist distance_m
from :schema.tmp_way_starts ts
join lateral (
    select ua.way_osm_id, ua.geom_3857,
           st_distance(ts.geom::geography, ua.geom::geography) dist
    from :schema.tmp_unconnected_areas ua
    where ua.geom_3857 && st_expand(ts.geom_3857, 3000)
        and st_dwithin(ts.geom::geography, ua.geom::geography, 300) -- TODO: порог (м) требует подбора на реальных данных
    order by ua.geom_3857 <-> ts.geom_3857
    limit 1
) pond on true
join :schema.tmp_final_clusters fc on fc.way_osm_id = pond.way_osm_id
join :schema.tmp_unconnected_areas pua on pua.way_osm_id = pond.way_osm_id
where not exists (
    select 1
    from :schema.tmp_waterway_lines wl
    where wl.way_osm_id <> ts.way_osm_id
        and wl.geom_3857 && st_expand(ts.geom_3857, 3000)
        and st_dwithin(wl.geom_simple::geography, ts.geom::geography, pond.dist)
)
union all
select
    pond.way_osm_id  wa_osm_id,
    fc.cluster_id,
    fc.cluster_size,
    'inflow'         direction,
    te.way_osm_id,
    st_transform(st_makeline(te.geom_3857, st_closestpoint(pua.geom_3857, te.geom_3857)), 4326) geom,
    pond.dist distance_m
from :schema.tmp_way_ends te
join lateral (
    select ua.way_osm_id, ua.geom_3857,
           st_distance(te.geom::geography, ua.geom::geography) dist
    from :schema.tmp_unconnected_areas ua
    where ua.geom_3857 && st_expand(te.geom_3857, 3000)
        and st_dwithin(te.geom::geography, ua.geom::geography, 300) -- TODO: тот же порог
    order by ua.geom_3857 <-> te.geom_3857
    limit 1
) pond on true
join :schema.tmp_final_clusters fc on fc.way_osm_id = pond.way_osm_id
join :schema.tmp_unconnected_areas pua on pua.way_osm_id = pond.way_osm_id
where not exists (
    select 1
    from :schema.tmp_waterway_lines wl
    where wl.way_osm_id <> te.way_osm_id
        and wl.geom_3857 && st_expand(te.geom_3857, 3000)
        and st_dwithin(wl.geom_simple::geography, te.geom::geography, pond.dist)
);

create index on :schema.tmp_pond_candidates(cluster_id, direction);

-- Anchor-коннектор на кластер: минимальная дистанция среди ВСЕХ участников, отдельно по каждому
-- направлению (0-2 строки на кластер). Кандидат (way_osm_id) и его победа в выборке уже решены
-- через дистанцию до тупика (start/end узла, tmp_pond_candidates) — это нужно для определения
-- направления и для честного сравнения с конкурирующими водотоками. Но САМУ геометрию связки и
-- итоговый distance_m пересчитываем по ПОЛНОЙ линии кандидата (не по узлу): тупик может быть
-- физически дальше от пруда, чем ближайшая точка где-то посередине этой же линии (найдено
-- эмпирически 2026-08-03: узел в 49м, ближайшая точка на той же 2-точечной линии — в 21м).
drop table if exists :schema.err_possible_isolated_water_areas cascade;
create table :schema.err_possible_isolated_water_areas as
with anchors as (
    select distinct on (pc.cluster_id, pc.direction)
        pc.wa_osm_id, pc.way_osm_id, pc.direction,
        pc.cluster_id, pc.cluster_size, cm.members cluster_members
    from :schema.tmp_pond_candidates pc
    join :schema.tmp_cluster_members cm using(cluster_id)
    order by pc.cluster_id, pc.direction, pc.distance_m
)
select
    a.wa_osm_id, a.way_osm_id, a.direction,
    case a.direction
        when 'outflow' then st_makeline(
            st_closestpoint(ua.geom_3857, st_transform(ww.geom, 3857)),
            st_closestpoint(st_transform(ww.geom, 3857), ua.geom_3857)
        )
        else st_makeline(
            st_closestpoint(st_transform(ww.geom, 3857), ua.geom_3857),
            st_closestpoint(ua.geom_3857, st_transform(ww.geom, 3857))
        )
    end geom,
    st_distance(ua.geom::geography, ww.geom::geography) distance_m,
    a.cluster_id, a.cluster_size, a.cluster_members
from anchors a
join :schema.tmp_unconnected_areas ua on ua.way_osm_id = a.wa_osm_id
join :schema.osm_ways ww on ww.way_osm_id = a.way_osm_id;

alter table :schema.err_possible_isolated_water_areas
    alter column geom type geometry(LineString,4326) using st_transform(geom,4326);

create index on :schema.err_possible_isolated_water_areas using gist(geom);
create index on :schema.err_possible_isolated_water_areas(wa_osm_id);
create index on :schema.err_possible_isolated_water_areas(cluster_id);

-- Полностью изолированные каскады (2-10 участников, ни у одного нет ни одного кандидата в
-- пределах порога ни в одном направлении) — то самое "проблема 2" из обсуждения: раньше такой
-- каскад либо пропадал молча, либо часть его участников получала неверный далёкий коннектор.
drop table if exists :schema.err_isolated_water_clusters cascade;
create table :schema.err_isolated_water_clusters as
select cm.cluster_id, cm.cluster_size, cm.members cluster_members, st_multi(st_union(ua.geom)) geom
from :schema.tmp_cluster_members cm
join :schema.tmp_unconnected_areas ua on ua.way_osm_id = any(cm.members)
where cm.cluster_size >= 2
    and not exists (select 1 from :schema.tmp_pond_candidates pc where pc.cluster_id = cm.cluster_id)
group by cm.cluster_id, cm.cluster_size, cm.members;

alter table :schema.err_isolated_water_clusters
    alter column geom type geometry(MultiPolygon,4326) using st_setsrid(geom,4326);

create index on :schema.err_isolated_water_clusters using gist(geom);
create index on :schema.err_isolated_water_clusters(cluster_id);

-- Связки для "брошенных" КОНЦОВ водотоков (только устья — начала намеренно не трогаем, по
-- запросу) — те же настоящие тупики (tmp_way_ends), для которых НЕ нашлось пруда (либо пруда
-- рядом вообще нет, либо конкурирующий водоток оказался ближе — см.
-- err_possible_isolated_water_areas выше), но нашёлся другой водоток поблизости.
-- Обобщает err_possible_missing_segments2 (тот скоуплен только на тупики, касающиеся
-- water=river-полигона, и на теги river/canal) на ЛЮБОЙ настоящий брошенный конец реки/ручья/
-- канала/канавы/дрены по всей стране, с тем же честным geography-порогом и той же
-- материализованной tmp_waterway_lines, что уже посчитана выше. err_possible_missing_segments2
-- не трогаем — отдельный алгоритм, оставлен как есть.
--
-- Дополнительно исключаем тупики с bnk > 0 — они уже физически касаются контура площадного
-- водоёма (err_unconnected_to_network их и так ловит, а если у того же водоёма найдётся ещё и
-- исток/выход — err_possible_missing_segments уже предложит flowline через него). Без этого
-- фильтра получали задвоение: один и тот же "брошенный у озера" водоток одновременно предлагался
-- и как flowline-кандидат (через err_possible_missing_segments/err_unconnected_to_network), и как
-- связка с посторонним, не относящимся к делу водотоком здесь — для него "уже всё отстроено".
--
-- advisory, как err_possible_missing_segments/2 — не входит в err_all (в отличие от
-- err_possible_isolated_water_areas/err_isolated_water_clusters, для которых включение в err_all
-- было отдельным явным решением).
create index on :schema.tmp_pond_candidates(way_osm_id, direction);

drop table if exists :schema.err_possible_waterway_gaps cascade;
create table :schema.err_possible_waterway_gaps as
select
    te.way_osm_id,
    wl.way_osm_id other_way_osm_id,
    st_transform(st_makeline(te.geom_3857, st_closestpoint(wl.geom_3857, te.geom_3857)), 4326) geom,
    st_distance(te.geom::geography, wl.geom_simple::geography) distance_m
from :schema.tmp_way_ends te
join lateral (
    select wl.way_osm_id, wl.geom_3857, wl.geom_simple
    from :schema.tmp_waterway_lines wl
    where wl.way_osm_id <> te.way_osm_id
        and wl.geom_3857 && st_expand(te.geom_3857, 3000)
        and st_dwithin(wl.geom_simple::geography, te.geom::geography, 300) -- тот же порог, TODO как и везде
    order by wl.geom_3857 <-> te.geom_3857
    limit 1
) wl on true
where te.bnk = 0
    and not exists (
        select 1 from :schema.tmp_pond_candidates pc
        where pc.way_osm_id = te.way_osm_id and pc.direction = 'inflow'
    );

alter table :schema.err_possible_waterway_gaps
    alter column geom type geometry(LineString,4326) using st_setsrid(geom,4326);

create index on :schema.err_possible_waterway_gaps using gist(geom);
create index on :schema.err_possible_waterway_gaps(way_osm_id);

drop table :schema.tmp_way_starts;
drop table :schema.tmp_way_ends;
drop table :schema.tmp_unconnected_areas;
drop table :schema.tmp_pond_edges;
drop table :schema.tmp_edges_sym;
drop table :schema.tmp_cluster_labels;
drop table :schema.tmp_final_clusters;
drop table :schema.tmp_cluster_members;
drop table :schema.tmp_pond_candidates;
drop table :schema.tmp_waterway_lines;





drop table if exists :schema.err_types;

-- Materialized on purpose, not a CTE: this table gets self-joined twice below
-- (directly, and again inside `exceptions`) on pnt_osm_id. As an inline CTE, Postgres
-- has no stats/index for that self-join and picked an unindexed nested loop instead of
-- an indexed one — see EXPLAIN ANALYZE before/after in the git history of this file.
-- Verified identical output before switching (row-for-row diff against the CTE version).
-- Dropped again once err_types is built — only needed here.
drop table if exists :schema.tmp_err_types_ways;
create table :schema.tmp_err_types_ways as
select ww.way_osm_id, ww.tags, ww.geom, pnt_osm_id, ww.nodes
from :schema.graph_nodes_stat_agg sa
join :schema.graph_nodes_stat ns using(pnt_osm_id)
join :schema.osm_ways ww using(way_osm_id)
where   sa."end" > 0
    and (sa.mid > 0 or sa.str > 0);

create index on :schema.tmp_err_types_ways(pnt_osm_id);
create index on :schema.tmp_err_types_ways(way_osm_id);
analyze :schema.tmp_err_types_ways;

create table :schema.err_types as
with exceptions as (
    select wi.way_osm_id
    from :schema.tmp_err_types_ways wi
    join :schema.tmp_err_types_ways wo using(pnt_osm_id)
    where   wi.nodes[cardinality(wi.nodes)] =  wi.pnt_osm_id
        and wo.nodes[cardinality(wo.nodes)] <> wo.pnt_osm_id
        and wi.tags ->> 'waterway' in ('river', 'canal')
        and wo.tags ->> 'waterway' in ('river', 'canal')
)
select wo.way_osm_id, wo.tags, wo.geom, st_endpoint(wi.geom) in_pnt
from :schema.tmp_err_types_ways wi
join :schema.tmp_err_types_ways wo using(pnt_osm_id)
left join exceptions    ex
    on ex.way_osm_id = wi.way_osm_id
where   wi.nodes[cardinality(wi.nodes)] =  wi.pnt_osm_id
    and wo.nodes[cardinality(wo.nodes)] <> wo.pnt_osm_id
    and wi.tags ->> 'waterway' in ('river', 'canal')
    and wo.tags ->> 'waterway' not in ('river', 'canal')
    and ex.way_osm_id is null;

drop table :schema.tmp_err_types_ways;

-- geom (passed through from typed osm_ways) is already LineString; in_pnt is computed
-- via st_endpoint() and comes back untyped — constrain it too so QGIS can load it as points.
alter table :schema.err_types alter column in_pnt type geometry(Point,4326) using st_setsrid(in_pnt,4326);

create index on :schema.err_types using gist(geom);
create index on :schema.err_types using gist(in_pnt);



-----------------------------------------------------
-- Проверки тегов
-----------------------------------------------------

drop table if exists :schema.err_possible_tagging_mistakes;
create table :schema.err_possible_tagging_mistakes as 
with errors as (
    -- 6-1 (culverts over 100 m long) disabled — no longer relevant, see project chat 2026-07-29.
    -- select
    --     way_osm_id,
    --     '6-1' err_id
    -- from :schema.osm_ways
    -- where   tags ->> 'tunnel' = 'culvert'
    --     and st_length(geom::geography) > 100
    -- ---------
    -- union all
    ---------
    -- waterway + bridge <> 'aqueduct'
    select 
        way_osm_id,
        '6-2' err_id
    --    'http://localhost:8111/load_object?objects=w' || way_osm_id edit_in_josm,
    from :schema.osm_ways
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
    from :schema.osm_areas
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
    from :schema.osm_areas
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
    from :schema.osm_areas
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
    from :schema.osm_areas
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
    from :schema.osm_ways, jsonb_object_keys(tags) keys
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
    from :schema.osm_ways
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
    from :schema.osm_ways
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
    from :schema.osm_areas
    where   tags ->> 'name' ~ '(\yр\.|\yруч\.|\кан\.\y|\yпрот\.|\yовр\.|\yпор\.|\yрод\.|\yсух\.|\yб\.|\yбол\.|\yбр\.|\yвдп\.|\yвдхр\.|\yбол\.|\yоз\.|\yпр\.)'
    ---------
    union all
    ---------
    -- 'waterway' = 'wadi' — deprecated тег (OSM wiki), независимо от геометрии
    select way_osm_id, '6-51' err_id
    from :schema.osm_ways
    where tags ->> 'waterway' = 'wadi'
    ---------
    union all
    ---------
    select way_osm_id, '6-51' err_id
    from :schema.osm_areas
    where tags ->> 'waterway' = 'wadi'
    ---------
    union all
    ---------
    -- 'waterway' = 'waterfall' на линии — по конвенции OSM это node
    select way_osm_id, '6-52' err_id
    from :schema.osm_ways
    where tags ->> 'waterway' = 'waterfall'
    ---------
    union all
    ---------
    -- 'waterway' = 'oxbow' на линии — см. 6-23 (тот же теговый вопрос, площадной случай)
    select way_osm_id, '6-53' err_id
    from :schema.osm_ways
    where tags ->> 'waterway' = 'oxbow'
    ---------
    union all
    ---------
    -- 'natural' = 'water'/'wetland' на линейном объекте — эти теги только для площадных объектов
    select way_osm_id,
        case
            when tags ->> 'natural' = 'water'   then '6-54'
            when tags ->> 'natural' = 'wetland'  then '6-55'
        end err_id
    from :schema.osm_ways
    where tags ->> 'natural' in ('water', 'wetland')
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
    --from :schema.osm_ways
    --where   tags ->> 'waterway' <> 'river'
    --    and tags ->> 'name' ~* '^.+(([гвбмкшщ]|к[сш]|)а|[нл]я)$'
    --
)
select way_osm_id, array_agg(err_id) err_list
from errors
group by way_osm_id
;


-- Таблица кодов ошибок
drop table if exists :schema.err_codes; 
create table :schema.err_codes as 
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
        ('6-50',    'Судя по названию, это может быть ''waterway'' = ''river'''),
        ('6-51',    '''waterway'' = ''wadi'' — устаревший тег (deprecated в OSM wiki). Замените на ''waterway'' = ''river''/''stream'' + ''intermittent'' = ''yes'', либо ''natural'' = ''valley'' — по месту'),
        ('6-52',    '''waterway'' = ''waterfall'' на линии — по конвенции OSM это точка (node)'),
        ('6-53',    '''waterway'' = ''oxbow'' на линии — рекомендуется ''natural'' = ''water'' + ''water'' = ''oxbow'' на полигоне (см. также 6-23)'),
        ('6-54',    '''natural'' = ''water'' на линейном объекте — этот тег для площадных объектов, нужен контур'),
        ('6-55',    '''natural'' = ''wetland'' на линейном объекте — этот тег для площадных объектов, нужен контур'),
        -- Изолированные водоёмы / каскады прудов (см. err_possible_isolated_water_areas,
        -- err_isolated_water_clusters):
        ('7-1',     'Водоём (или каскад прудов) не связан с сетью водотоков — рядом найден кандидат на исходящую связку. Предлагаемое решение — waterway=flowline от водоёма к кандидату, см. https://wiki.openstreetmap.org/wiki/Tag:waterway=flowline (см. err_possible_isolated_water_areas)'),
        ('7-2',     'Водоём (или каскад прудов) не связан с сетью водотоков — рядом найден кандидат на входящую связку. Предлагаемое решение — waterway=flowline от кандидата к водоёму, см. https://wiki.openstreetmap.org/wiki/Tag:waterway=flowline (см. err_possible_isolated_water_areas)'),
        ('7-3',     'Каскад из 2-10 изолированных водоёмов — ни у одного участника нет ни одного кандидата на связку в пределах порога расстояния, предложить waterway=flowline не удалось (см. err_isolated_water_clusters)')
) errs(err_id, description);




-- Все ошибки в одной таблице (с маппингом расшифровок через коды)
drop table if exists :schema.err_all; 
create table :schema.err_all as 
with errors as (
    select way_osm_id osm_id, '1' err_id from :schema.err_duplicated_areas
    union all
    select way_osm_id osm_id, '1' err_id from :schema.err_duplicated_ways
    union all
    select osm_id, '2' err_id from :schema.err_overlapping_ways, unnest(osm_ids) osm_id 
    union all
    select way_osm_id osm_id, '3' err_id from :schema.err_possible_wrong_dir
    union all
    select way_osm_id osm_id, '4' err_id from :schema.err_types
    union all
    select way_osm_id osm_id, '5' err_id from :schema.err_unconnected_to_network
    union all
    select way_osm_id osm_id, err_id
    from :schema.err_possible_tagging_mistakes, unnest(err_list) err_id
    union all
    -- err_possible_isolated_water_areas/err_isolated_water_clusters сами по себе остаются
    -- advisory (см. их комментарий выше), но ВСЕ участники кластера (cluster_members, не только
    -- anchor-пруд) и кандидат-водоток помечаются в err_all, чтобы подсвечивались в обычных слоях
    -- (в дополнение к отдельным слоям со связкой/каскадом).
    select m osm_id, case direction when 'outflow' then '7-1' else '7-2' end err_id
    from :schema.err_possible_isolated_water_areas, unnest(cluster_members) m
    union all
    select way_osm_id osm_id, case direction when 'outflow' then '7-1' else '7-2' end err_id
    from :schema.err_possible_isolated_water_areas
    union all
    select m osm_id, '7-3' err_id
    from :schema.err_isolated_water_clusters, unnest(cluster_members) m
)
select 
    osm_id, 
    array_agg(distinct err_id) err_ids,
    array_agg(distinct description) err_list    
from errors                 er
left join :schema.err_codes   ec using(err_id)
where err_id is not null
group by osm_id;

create index on :schema.err_all(osm_id);






