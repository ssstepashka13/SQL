-- Проверки выполняются после project.sql. Тестовые данные откатываются.
BEGIN;

DO $$
DECLARE
    _a uuid := gen_random_uuid();
    _b uuid := gen_random_uuid();
    _c uuid := gen_random_uuid();
    _d uuid := gen_random_uuid();
    _project uuid := gen_random_uuid();
    _bonus_project uuid;
    _salary_project uuid := gen_random_uuid();
    _n bigint;
    _before bigint;
    _rate integer;
    _expected integer;
    _estimate integer;
    _bonus integer;
    _r record;
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.employees e
        WHERE NOT EXISTS (
            SELECT 1 FROM public.employee_rate_history h
            WHERE h.employee_id = e.id AND h.from_date = DATE '2020-12-26'
        )
    ) THEN
        RAISE EXCEPTION 'Initial rate history is incomplete';
    END IF;

    INSERT INTO public.employees(id, name, email, rate) VALUES
        (_a, 'Validation A', _a::text || '@test.invalid', 1000),
        (_b, 'Validation B', _b::text || '@test.invalid', 2000),
        (_c, 'Validation C', _c::text || '@test.invalid', 600),
        (_d, 'Validation D', _d::text || '@test.invalid', 1000);

    SELECT COUNT(*) INTO _n FROM public.employee_rate_history
    WHERE employee_id IN (_a, _b, _c, _d) AND from_date = CURRENT_DATE;
    IF _n <> 4 THEN RAISE EXCEPTION 'Employee insert history failed'; END IF;

    CALL public.update_employees_rate(json_build_array(
        json_build_object('employee_id', _a, 'rate_change', 10),
        json_build_object('employee_id', _b, 'rate_change', -90)
    ));
    IF (SELECT rate FROM public.employees WHERE id = _a) <> 1100
       OR (SELECT rate FROM public.employees WHERE id = _b) <> 500 THEN
        RAISE EXCEPTION 'Rate update or minimum rate failed';
    END IF;

    CALL public.update_employees_rate(json_build_array(
        json_build_object('employee_id', _a, 'rate_change', 10),
        json_build_object('employee_id', _a, 'rate_change', -5)
    ));
    IF (SELECT rate FROM public.employees WHERE id = _a) <> 1150 THEN
        RAISE EXCEPTION 'Sequential changes and rounding failed';
    END IF;

    SELECT COUNT(*) INTO _before FROM public.employee_rate_history WHERE employee_id = _a;
    UPDATE public.employees SET rate = rate, name = name || ' updated' WHERE id = _a;
    IF (SELECT COUNT(*) FROM public.employee_rate_history WHERE employee_id = _a) <> _before THEN
        RAISE EXCEPTION 'Unchanged rate created a history record';
    END IF;

    BEGIN
        CALL public.update_employees_rate(json_build_array(
            json_build_object('employee_id', _a, 'rate_change', 10),
            json_build_object('employee_id', gen_random_uuid(), 'rate_change', 10)
        ));
        RAISE EXCEPTION 'Missing employee was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'Missing employee was accepted' THEN RAISE; END IF;
    END;
    IF (SELECT rate FROM public.employees WHERE id = _a) <> 1150 THEN
        RAISE EXCEPTION 'Failed batch was not rolled back';
    END IF;

    CREATE TEMP TABLE validation_rates ON COMMIT DROP AS
    SELECT e.id, ROUND(e.rate * (
        1 + (5::numeric + CASE WHEN e.rate < AVG(e.rate) OVER () THEN 2 ELSE 0 END) / 100
    ))::integer AS expected_rate
    FROM public.employees e;
    CALL public.indexing_salary(5);
    IF EXISTS (
        SELECT 1 FROM public.employees e JOIN validation_rates v USING (id)
        WHERE e.rate <> v.expected_rate
    ) THEN RAISE EXCEPTION 'Indexation used an incorrect average'; END IF;

    UPDATE public.employees SET rate = 1000 WHERE id = _a;
    INSERT INTO public.projects(id, name, estimated_time, is_active)
    VALUES (_project, 'Validation open project', 1000, true),
           (_salary_project, 'Validation salary', 1000, true);

    CALL public.log_work(_a, _project, CURRENT_DATE, 16);
    IF (SELECT required_review FROM public.logs WHERE employee_id = _a
        AND project_id = _project AND work_date = CURRENT_DATE) THEN
        RAISE EXCEPTION 'Exactly 16 hours were incorrectly flagged';
    END IF;
    CALL public.log_work(_a, _project, CURRENT_DATE, 1);
    IF NOT EXISTS (SELECT 1 FROM public.logs WHERE employee_id = _a
        AND project_id = _project AND work_date = CURRENT_DATE
        AND work_hours = 1 AND required_review) THEN
        RAISE EXCEPTION 'Daily total above 16 hours was not flagged';
    END IF;
    CALL public.log_work(_a, _project, CURRENT_DATE - 7, 1);
    CALL public.log_work(_a, _project, CURRENT_DATE - 8, 1);
    CALL public.log_work(_a, _project, CURRENT_DATE + 1, 1);
    CALL public.log_work(_a, _project, CURRENT_DATE - 1, 24);
    IF (SELECT required_review FROM public.logs WHERE employee_id = _a
        AND project_id = _project AND work_date = CURRENT_DATE - 7)
       OR EXISTS (SELECT 1 FROM public.logs WHERE employee_id = _a
           AND project_id = _project
           AND work_date IN (CURRENT_DATE - 8, CURRENT_DATE + 1, CURRENT_DATE - 1)
           AND NOT required_review) THEN
        RAISE EXCEPTION 'Date or 24-hour review boundary failed';
    END IF;
    SELECT COUNT(*) INTO _before FROM public.logs WHERE project_id = _project;
    CALL public.log_work(_a, _project, CURRENT_DATE, 0);
    CALL public.log_work(_a, _project, CURRENT_DATE, 25);
    CALL public.log_work(_a, _project, CURRENT_DATE, NULL);
    IF (SELECT COUNT(*) FROM public.logs WHERE project_id = _project) <> _before THEN
        RAISE EXCEPTION 'Invalid hours inserted a log';
    END IF;

    -- Бонус: предел 16, округление вниз, отсутствие бюджета и перерасход.
    FOREACH _estimate IN ARRAY ARRAY[100, 40, NULL, 20, 31]
    LOOP
        _bonus_project := gen_random_uuid();
        INSERT INTO public.projects(id, name, estimated_time, is_active)
        VALUES (_bonus_project, 'Validation bonus', _estimate, true);
        INSERT INTO public.logs(employee_id, project_id, work_date, work_hours)
        SELECT x, _bonus_project, CURRENT_DATE - 10, 10 FROM unnest(ARRAY[_a, _b, _c]) x;
        _bonus := CASE _estimate WHEN 100 THEN 16 WHEN 40 THEN 2 ELSE 0 END;
        CALL public.close_project(_bonus_project);
        SELECT COUNT(*) INTO _n FROM public.logs WHERE project_id = _bonus_project;
        IF _n <> (CASE WHEN _bonus > 0 THEN 6 ELSE 3 END)
           OR (SELECT is_active FROM public.projects WHERE id = _bonus_project)
           OR EXISTS (SELECT 1 FROM public.logs WHERE project_id = _bonus_project
               AND work_date = CURRENT_DATE AND work_hours <> _bonus) THEN
            RAISE EXCEPTION 'Bonus calculation failed for estimate %', _estimate;
        END IF;
        _before := _n;
        BEGIN
            CALL public.close_project(_bonus_project);
            RAISE EXCEPTION 'Repeated closure accepted';
        EXCEPTION WHEN raise_exception THEN
            IF SQLERRM <> 'Project closed' THEN RAISE; END IF;
        END;
        IF (SELECT COUNT(*) FROM public.logs WHERE project_id = _bonus_project) <> _before THEN
            RAISE EXCEPTION 'Repeated closure duplicated bonus';
        END IF;
        BEGIN
            CALL public.log_work(_a, _bonus_project, CURRENT_DATE, 1);
            RAISE EXCEPTION 'Closed project accepted work';
        EXCEPTION WHEN raise_exception THEN
            IF SQLERRM <> 'Project closed' THEN RAISE; END IF;
        END;
    END LOOP;

    _bonus_project := gen_random_uuid();
    INSERT INTO public.projects(id, name, estimated_time, is_active)
    VALUES (_bonus_project, 'Validation empty project', 100, true);
    CALL public.close_project(_bonus_project);
    IF EXISTS (SELECT 1 FROM public.logs WHERE project_id = _bonus_project) THEN
        RAISE EXCEPTION 'Empty project received bonus';
    END IF;

    -- 161 оплачиваемый час, отдельно уже оплаченные и требующие проверки.
    INSERT INTO public.logs(employee_id, project_id, work_date, work_hours)
    SELECT _a, _salary_project, DATE '2024-04-01' + i, 16 FROM generate_series(0, 9) i;
    INSERT INTO public.logs(employee_id, project_id, work_date, work_hours, required_review, is_paid)
    VALUES (_a, _salary_project, DATE '2024-04-11', 1, false, false),
           (_a, _salary_project, DATE '2024-04-12', 8, true, false),
           (_a, _salary_project, DATE '2024-04-13', 8, false, true),
           (_a, _salary_project, DATE '2024-03-31', 8, false, false),
           (_a, _salary_project, DATE '2024-05-01', 8, false, false);
    SELECT * INTO _r FROM public.calculate_month_salary('2024-04-01', '2024-04-30')
    WHERE id = _a;
    IF NOT FOUND OR _r.worked_hours <> 161 OR _r.salary <> 161250 THEN
        RAISE EXCEPTION 'Salary overtime, flags or dates failed: %', _r;
    END IF;
    SELECT * INTO _r FROM public.calculate_month_salary('2024-04-01', '2024-04-10')
    WHERE id = _a;
    IF NOT FOUND OR _r.worked_hours <> 160 OR _r.salary <> 160000 THEN
        RAISE EXCEPTION 'Exactly 160 hours failed';
    END IF;

    -- Топ-3: при равенстве часов впереди сотрудник с большим числом дней.
    _bonus_project := gen_random_uuid();
    INSERT INTO public.projects(id, name, is_active)
    VALUES (_bonus_project, 'Validation top workers', true);
    INSERT INTO public.logs(employee_id, project_id, work_date, work_hours)
    VALUES (_a, _bonus_project, CURRENT_DATE - 2, 15),
           (_a, _bonus_project, CURRENT_DATE - 2, 15),
           (_b, _bonus_project, CURRENT_DATE - 2, 15),
           (_b, _bonus_project, CURRENT_DATE - 1, 15),
           (_c, _bonus_project, CURRENT_DATE - 1, 20),
           (_d, _bonus_project, CURRENT_DATE - 1, 10);
    SELECT * INTO _r FROM public.best_project_workers(_bonus_project) LIMIT 1;
    IF _r.employee <> 'Validation B' OR _r.work_hours <> 30 THEN
        RAISE EXCEPTION 'Top worker day tie-break failed';
    END IF;
    IF (SELECT COUNT(*) FROM public.best_project_workers(_bonus_project)) <> 3 THEN
        RAISE EXCEPTION 'Top worker limit failed';
    END IF;

    RAISE NOTICE 'All project checks passed';
END;
$$;

ROLLBACK;
