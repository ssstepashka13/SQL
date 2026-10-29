-- Проект 4. Gastro Hub Delivery. Часть 1.
-- Скрипт выполняется один раз на исходном дампе project_4.sql (PostgreSQL 15+).

-- Задание 1. Вставка заказов.
-- Причина: каждая вставка обновляет десять индексов. В orders_stat.sql используются
-- только order_id, order_dt и user_id; остальные семь индексов избыточны для этой нагрузки.
-- MAX(order_id)+1 дополнительно читает таблицу/индекс и небезопасен при одновременных вставках.
-- План: оставить индексы для показанных запросов, закрепить уникальность order_id,
-- заменить MAX+1 последовательностью. В приложении больше не передавать order_id.
BEGIN;
LOCK TABLE public.orders IN ACCESS EXCLUSIVE MODE;
CREATE SEQUENCE public.orders_order_id_seq AS bigint;
SELECT setval('public.orders_order_id_seq',
              GREATEST(COALESCE(MAX(order_id), 1), 1), MAX(order_id) IS NOT NULL)
FROM public.orders;
ALTER SEQUENCE public.orders_order_id_seq OWNED BY public.orders.order_id;
ALTER TABLE public.orders ALTER COLUMN order_id
    SET DEFAULT nextval('public.orders_order_id_seq');
DROP INDEX public.orders_order_id_idx;
ALTER TABLE public.orders ADD CONSTRAINT orders_pkey PRIMARY KEY (order_id);
DROP INDEX public.orders_city_id_idx,
           public.orders_device_type_city_id_idx,
           public.orders_device_type_idx,
           public.orders_discount_idx,
           public.orders_final_cost_idx,
           public.orders_total_cost_idx,
           public.orders_total_final_cost_discount_idx;
COMMIT;
ANALYZE public.orders;
-- Новый запрос приложения (пример, не выполняется при установке):
-- INSERT INTO public.orders
--     (order_dt, user_id, device_type, city_id, total_cost, discount, final_cost)
-- VALUES (current_timestamp, '329551a1-215d-43e6-baee-322f2467272d',
--         'Mobile', 1, 1000.00, NULL, 1000.00);
-- Перед удалением индексов в рабочей БД нужно проверить полный цикл реальной нагрузки.

-- Задание 2. Именинники.
-- Причина: строки char(500) увеличивают объём users, а функции и преобразования
-- birth_date и city_id выполняются для каждой строки при каждом поиске.
-- План: хранить UUID, дату и тексты в соответствующих типах; индексировать город,
-- месяц и день рождения. Остальные данные ответа включить в покрывающий индекс.
BEGIN;
ALTER TABLE public.users
    ALTER COLUMN user_id TYPE uuid USING user_id::text::uuid,
    ALTER COLUMN first_name TYPE text USING first_name::text,
    ALTER COLUMN last_name TYPE text USING last_name::text,
    ALTER COLUMN gender TYPE text USING gender::text,
    ALTER COLUMN birth_date TYPE date USING birth_date::text::date,
    ALTER COLUMN registration_date TYPE timestamp
        USING registration_date::text::timestamp,
    ALTER COLUMN city_id TYPE integer USING city_id::integer;
CREATE INDEX users_city_birthday_idx ON public.users
    (city_id, (EXTRACT(MONTH FROM birth_date)), (EXTRACT(DAY FROM birth_date)))
    INCLUDE (user_id, first_name, last_name, gender);
COMMIT;
ANALYZE public.users;
-- Для даты 31.12.2023 (в приложении передавать дату параметром):
SELECT user_id, first_name, last_name, city_id, gender
FROM public.users
WHERE city_id = 4
  AND EXTRACT(MONTH FROM birth_date) = EXTRACT(MONTH FROM DATE '2023-12-31')
  AND EXTRACT(DAY FROM birth_date) = EXTRACT(DAY FROM DATE '2023-12-31');

-- Задание 3. Оплата.
-- Причина: простая процедура PL/pgSQL по очереди выполняет три отдельных SQL-команды.
-- План: объединить независимые вставки одним SQL-выражением с изменяющими CTE,
-- сохранив параметры, статус 2, суммы и запись продажи для владельца заказа.
-- Последовательности имеют CACHE 1: увеличить кеш до 100, чтобы реже резервировать номера.
-- Это уменьшает накладные расходы выполнения; все три записи остаются атомарными.
-- Номера уникальны, но непрерывность нумерации не гарантируется.
ALTER SEQUENCE public.payments_payment_id_sq CACHE 100;
ALTER SEQUENCE public.sales_sale_id_sq CACHE 100;
CREATE OR REPLACE PROCEDURE public.add_payment(IN p_order_id bigint,
                                             IN p_sum_payment numeric)
LANGUAGE sql
AS $payment$
    WITH status_insert AS (
        INSERT INTO public.order_statuses(order_id, status_id, status_dt)
        VALUES (p_order_id, 2, statement_timestamp())
    ), payment_insert AS (
        INSERT INTO public.payments(payment_id, order_id, payment_sum)
        VALUES (nextval('public.payments_payment_id_sq'), p_order_id, p_sum_payment)
    )
    INSERT INTO public.sales(sale_id, sale_dt, user_id, sale_sum)
    SELECT nextval('public.sales_sale_id_sq'), statement_timestamp(), user_id, p_sum_payment
    FROM public.orders WHERE order_id = p_order_id;
$payment$;

-- Задание 4. Логи.
-- Причина: в user_logs более 4,6 млн строк; при записи обслуживаются PK и индекс
-- datetime, включая давно не используемую историю. Это увеличивает объём индексов
-- и нагрузку на запись; отдельно проверяются I/O, блокировки и работа autovacuum.
-- План: секционировать user_logs по datetime с квартальными границами [начало, конец).
-- Заранее создавать следующий квартал. Индексы создавать на секциях, а не дублировать
-- без необходимости. На холодных, упорядоченных по времени секциях использовать BRIN
-- либо убирать вторичные индексы, если история не запрашивается.
-- Запросы текущего квартала должны фильтровать datetime диапазоном без функции над
-- колонкой: datetime >= date_trunc('quarter', CURRENT_DATE)::timestamp
-- AND datetime < (date_trunc('quarter', CURRENT_DATE) + INTERVAL '3 months')::timestamp.
-- СУБД исключит старые секции; новые записи будут обслуживать небольшую активную секцию.
-- Старые кварталы отсоединять и переносить в архив по согласованному сроку хранения.
-- Миграция: создать секционированную таблицу, перенести историю, догнать изменения,
-- сверить количество/содержимое и переключить запись в коротком окне обслуживания.
-- При выборе PK учитывать: уникальный ключ секционированной таблицы обязан включать
-- datetime. Если нужен именно глобальный UNIQUE(log_id), его нельзя молча заменить
-- составным ключом; нужна отдельная таблица идентификаторов или сохранение старой схемы.
-- Сначала измерить задержку вставок, размер индексов и WAL на тестовой копии.
-- Решение этого задания представлено без миграционного скрипта, как разрешено условием.

-- Задание 5. Отчёт маркетологов.
-- Способ: один раз вычислить дневные доли в материализованном представлении.
-- Заказывать REFRESH после завершения загрузки предыдущего дня, один раз в сутки,
-- с единственным заданием планировщика. Маркетологи читают готовый небольшой результат.
-- Возраст рассчитывается на день заказа; количество блюд учитывает order_items.count.
-- Доля каждого признака независима: одно блюдо может быть одновременно рыбным и острым.
-- Граница дня определяется в часовом поясе отчётности Europe/Moscow.
CREATE MATERIALIZED VIEW public.marketing_daily_preferences AS
WITH order_days AS (
    SELECT order_id, user_id,
           (order_dt AT TIME ZONE 'Europe/Moscow')::date AS day
    FROM public.orders
    WHERE order_dt < (date_trunc('day', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
                      AT TIME ZONE 'Europe/Moscow')
), facts AS (
    SELECT o.day,
           EXTRACT(YEAR FROM age(o.day, u.birth_date))::integer AS years,
           oi.count AS quantity, d.spicy, d.fish, d.meat
    FROM order_days o
    JOIN public.users u ON u.user_id = o.user_id
    JOIN public.order_items oi ON oi.order_id = o.order_id
    JOIN public.dishes d ON d.object_id = oi.item
    WHERE oi.count > 0
), classified AS (
    SELECT *, CASE WHEN years > 0 AND years <= 20 THEN '0–20'
                   WHEN years > 20 AND years <= 30 THEN '20–30'
                   WHEN years > 30 AND years <= 40 THEN '30–40'
                   WHEN years > 40 AND years <= 100 THEN '40–100' END AS age
    FROM facts
), aggregated AS (
    SELECT day, age,
           round(100.0 * SUM(quantity) FILTER (WHERE spicy = 1) / SUM(quantity), 2) AS spicy,
           round(100.0 * SUM(quantity) FILTER (WHERE fish = 1) / SUM(quantity), 2) AS fish,
           round(100.0 * SUM(quantity) FILTER (WHERE meat = 1) / SUM(quantity), 2) AS meat
    FROM classified
    WHERE age IS NOT NULL
    GROUP BY day, age
), groups(age, ordinal) AS (
    VALUES ('0–20', 1), ('20–30', 2), ('30–40', 3), ('40–100', 4)
)
SELECT dates.day, g.age,
       COALESCE(a.spicy, 0::numeric) AS spicy,
       COALESCE(a.fish, 0::numeric) AS fish,
       COALESCE(a.meat, 0::numeric) AS meat
FROM (SELECT DISTINCT day FROM order_days) dates
CROSS JOIN groups g
LEFT JOIN aggregated a ON a.day = dates.day AND a.age = g.age;
CREATE UNIQUE INDEX marketing_daily_preferences_day_age_idx
    ON public.marketing_daily_preferences(day, age);
-- Ежесуточная команда планировщика (в отдельной сессии):
-- REFRESH MATERIALIZED VIEW CONCURRENTLY public.marketing_daily_preferences;
-- Отчёт для маркетолога:
SELECT day, age, spicy, fish, meat
FROM public.marketing_daily_preferences
ORDER BY day, CASE age WHEN '0–20' THEN 1 WHEN '20–30' THEN 2
                      WHEN '30–40' THEN 3 ELSE 4 END;
