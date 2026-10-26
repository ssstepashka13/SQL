-- Дополнительные проверки после project.sql. Только чтение данных.

SELECT 'raw_sales' AS object_name, COUNT(*) AS row_count FROM raw_data.sales
UNION ALL SELECT 'restaurants', COUNT(*) FROM cafe.restaurants
UNION ALL SELECT 'managers', COUNT(*) FROM cafe.managers
UNION ALL SELECT 'work_periods', COUNT(*) FROM cafe.restaurant_manager_work_dates
UNION ALL SELECT 'sales', COUNT(*) FROM cafe.sales
UNION ALL SELECT 'top_restaurants', COUNT(*) FROM cafe.top_restaurants
UNION ALL SELECT 'yearly_average_checks', COUNT(*) FROM cafe.yearly_average_checks;

-- Ожидается 0 потерянных/лишних продаж, без маскирования повторов DISTINCT.
WITH source AS (
    SELECT report_date, cafe_name, avg_check FROM raw_data.sales
), target AS (
    SELECT s.date, r.restaurant_name, s.avg_check
    FROM cafe.sales AS s JOIN cafe.restaurants AS r USING (restaurant_uuid)
)
SELECT 'missing_sales' AS problem, COUNT(*) AS row_count
FROM (SELECT * FROM source EXCEPT ALL SELECT * FROM target) AS missing
UNION ALL
SELECT 'extra_sales', COUNT(*)
FROM (SELECT * FROM target EXCEPT ALL SELECT * FROM source) AS extra;

-- Восстановление всех 8 исходных полей через справочники и периоды работы.
WITH source AS (
    SELECT report_date, cafe_name, type, avg_check,
           manager, manager_phone, latitude, longitude
    FROM raw_data.sales
), target AS (
    SELECT s.date, r.restaurant_name, r.restaurant_type::TEXT, s.avg_check,
           m.manager_name, m.phone,
           public.ST_Y(r.location), public.ST_X(r.location)
    FROM cafe.sales AS s
    JOIN cafe.restaurants AS r USING (restaurant_uuid)
    JOIN cafe.restaurant_manager_work_dates AS w
      ON w.restaurant_uuid = s.restaurant_uuid
     AND s.date BETWEEN w.start_date AND w.end_date
    JOIN cafe.managers AS m USING (manager_uuid)
)
SELECT 'missing_source_rows' AS problem, COUNT(*) AS row_count
FROM (SELECT * FROM source EXCEPT ALL SELECT * FROM target) AS missing
UNION ALL
SELECT 'extra_source_rows', COUNT(*)
FROM (SELECT * FROM target EXCEPT ALL SELECT * FROM source) AS extra;

-- Меню перенесены без изменений. Ожидается 0.
SELECT COUNT(*) AS menu_mismatches
FROM cafe.restaurants AS r
FULL JOIN raw_data.menu AS m ON m.cafe_name = r.restaurant_name
WHERE r.restaurant_name IS NULL OR m.cafe_name IS NULL
   OR r.menu IS DISTINCT FROM m.menu;

-- Пересечения периодов разных менеджеров одного ресторана. Ожидается 0.
SELECT COUNT(*) AS overlapping_periods
FROM cafe.restaurant_manager_work_dates AS w1
JOIN cafe.restaurant_manager_work_dates AS w2
  ON w1.restaurant_uuid = w2.restaurant_uuid
 AND w1.manager_uuid < w2.manager_uuid
 AND daterange(w1.start_date, w1.end_date, '[]')
     && daterange(w2.start_date, w2.end_date, '[]');

SELECT restaurant_type, COUNT(*) AS top_count
FROM cafe.top_restaurants
GROUP BY restaurant_type ORDER BY restaurant_type;

SELECT MIN(year) AS first_year, MAX(year) AS last_year,
       COUNT(*) FILTER (WHERE year = 2023) AS excluded_year_rows,
       COUNT(*) FILTER (WHERE previous_avg_check IS NULL) AS first_year_nulls
FROM cafe.yearly_average_checks;

-- Геометрия должна быть валидной точкой с указанной системой координат.
SELECT COUNT(*) AS invalid_locations
FROM cafe.restaurants
WHERE NOT public.ST_IsValid(location)
   OR public.ST_SRID(location) <> 4326
   OR public.GeometryType(location) <> 'POINT';

-- Районы без заведений тоже участвуют в задании 7.
SELECT d.district_name, COUNT(r.restaurant_uuid) AS restaurant_count
FROM cafe.districts AS d
LEFT JOIN cafe.restaurants AS r ON public.ST_Covers(d.district_geom, r.location)
GROUP BY d.id, d.district_name
ORDER BY restaurant_count DESC, d.district_name;
