-- Проверки после project.sql. Изменения данных и представления откатываются.
-- Последовательности могут получить пропуски: nextval не откатывается.
BEGIN;

DO $test$
DECLARE
    first_id bigint;
    second_id bigint;
    previous_max bigint;
    status_count bigint;
    payment_count bigint;
    sale_count bigint;
BEGIN
    SELECT MAX(order_id) INTO previous_max FROM public.orders;
    INSERT INTO public.orders(order_dt,user_id,device_type,city_id,total_cost,final_cost)
    VALUES (CURRENT_TIMESTAMP,'329551a1-215d-43e6-baee-322f2467272d','Mobile',1,1000,1000)
    RETURNING order_id INTO first_id;
    INSERT INTO public.orders(order_dt,user_id,device_type,city_id,total_cost,final_cost)
    VALUES (CURRENT_TIMESTAMP,'329551a1-215d-43e6-baee-322f2467272d','Mobile',1,1000,1000)
    RETURNING order_id INTO second_id;
    IF first_id <= previous_max OR second_id <= first_id THEN
        RAISE EXCEPTION 'Ошибка генерации order_id';
    END IF;
    IF (SELECT COUNT(*) FROM pg_indexes WHERE schemaname='public' AND tablename='orders') <> 3 THEN
        RAISE EXCEPTION 'Ожидалось три индекса orders';
    END IF;
    SELECT COUNT(*) INTO status_count FROM public.order_statuses;
    SELECT COUNT(*) INTO payment_count FROM public.payments;
    SELECT COUNT(*) INTO sale_count FROM public.sales;
    CALL public.add_payment(first_id,1000.00);
    IF (SELECT COUNT(*) FROM public.order_statuses) <> status_count+1
       OR (SELECT COUNT(*) FROM public.payments) <> payment_count+1
       OR (SELECT COUNT(*) FROM public.sales) <> sale_count+1 THEN
        RAISE EXCEPTION 'Процедура не создала три записи';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.order_statuses
                   WHERE order_id=first_id AND status_id=2 AND status_dt IS NOT NULL)
       OR NOT EXISTS (SELECT 1 FROM public.payments WHERE order_id=first_id AND payment_sum=1000)
       OR NOT EXISTS (SELECT 1 FROM public.sales
                     WHERE user_id='329551a1-215d-43e6-baee-322f2467272d' AND sale_sum=1000) THEN
        RAISE EXCEPTION 'Неверные данные оплаты';
    END IF;
END;
$test$;

-- Принудительная ошибка в последней вставке: частичные записи недопустимы.
CREATE FUNCTION public.validation_reject_sale() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN RAISE EXCEPTION 'validation sale failure'; END;
$f$;
CREATE TRIGGER validation_reject_sale BEFORE INSERT ON public.sales
FOR EACH ROW WHEN (NEW.sale_sum = -777) EXECUTE FUNCTION public.validation_reject_sale();
DO $test$
DECLARE s bigint; p bigint; a bigint; failed boolean := false;
BEGIN
    SELECT COUNT(*) INTO s FROM public.order_statuses;
    SELECT COUNT(*) INTO p FROM public.payments;
    SELECT COUNT(*) INTO a FROM public.sales;
    BEGIN
        CALL public.add_payment(153,-777);
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'validation sale failure' THEN RAISE; END IF;
        failed := true;
    END;
    IF NOT failed OR (SELECT COUNT(*) FROM public.order_statuses) <> s
       OR (SELECT COUNT(*) FROM public.payments) <> p
       OR (SELECT COUNT(*) FROM public.sales) <> a THEN
        RAISE EXCEPTION 'Нарушена атомарность оплаты';
    END IF;
END;
$test$;

-- Граничные возрасты и вес блюд в отчёте; отдельный день вне исходных данных.
INSERT INTO public.dishes(object_id,name,spicy,fish,meat,rest_id) VALUES
    (-900001,'test spicy',1,0,0,'validation'),
    (-900002,'test fish',0,1,0,'validation'),
    (-900003,'test meat',0,0,1,'validation'),
    (-900004,'test fish and meat',0,1,1,'validation');
DO $test$
DECLARE x record; uid uuid; oid bigint;
BEGIN
    FOR x IN SELECT * FROM (VALUES
        (0,-900001::bigint,999::bigint),
        (1,-900001,1), (20,-900002,3),
        (21,-900003,1), (30,-900001,3),
        (31,-900002,1), (40,-900003,3),
        (41,-900001,1), (100,-900004,3),
        (101,-900001,999)
    ) AS cases(years,dish,quantity)
    LOOP
        uid := ('00000000-0000-4000-8000-'||lpad(x.years::text,12,'0'))::uuid;
        INSERT INTO public.users(user_id,first_name,last_name,city_id,gender,birth_date,registration_date)
        VALUES(uid,'Test','Age',1,'test',make_date(2000-x.years,1,1),TIMESTAMP '1999-01-01');
        INSERT INTO public.orders(order_dt,user_id,device_type,city_id,total_cost,final_cost)
        VALUES(TIMESTAMPTZ '2000-01-01 12:00:00+03',uid,'Mobile',1,100,100)
        RETURNING order_id INTO oid;
        INSERT INTO public.order_items(order_id,item,count) VALUES(oid,x.dish,x.quantity);
    END LOOP;
    -- Текущий день обязательно исключается.
    INSERT INTO public.orders(order_dt,user_id,device_type,city_id,total_cost,final_cost)
    VALUES(CURRENT_TIMESTAMP,uid,'Mobile',1,100,100) RETURNING order_id INTO oid;
    INSERT INTO public.order_items(order_id,item,count) VALUES(oid,-900001,999);
END;
$test$;
REFRESH MATERIALIZED VIEW public.marketing_daily_preferences;
DO $test$
DECLARE
    actual jsonb;
    expected jsonb := '[{"age":"0–20","spicy":25,"fish":75,"meat":0},
                       {"age":"20–30","spicy":75,"fish":0,"meat":25},
                       {"age":"30–40","spicy":0,"fish":25,"meat":75},
                       {"age":"40–100","spicy":25,"fish":75,"meat":75}]';
BEGIN
    SELECT jsonb_agg(jsonb_build_object('age',age,'spicy',spicy,'fish',fish,'meat',meat)
                     ORDER BY CASE age WHEN '0–20' THEN 1 WHEN '20–30' THEN 2
                                       WHEN '30–40' THEN 3 ELSE 4 END)
      INTO actual FROM public.marketing_daily_preferences WHERE day=DATE '2000-01-01';
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'Неверные границы/веса отчёта: %',actual;
    END IF;
    IF EXISTS (SELECT 1 FROM public.marketing_daily_preferences
               WHERE day >= (CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')::date
                  OR spicy NOT BETWEEN 0 AND 100 OR fish NOT BETWEEN 0 AND 100
                  OR meat NOT BETWEEN 0 AND 100) THEN
        RAISE EXCEPTION 'Неверные даты или проценты';
    END IF;
    IF EXISTS (SELECT day FROM public.marketing_daily_preferences GROUP BY day HAVING COUNT(*)<>4) THEN
        RAISE EXCEPTION 'Для дня отсутствует одна из четырёх групп';
    END IF;
END;
$test$;
ROLLBACK;
