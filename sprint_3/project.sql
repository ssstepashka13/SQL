BEGIN;

-- 1. Изменение ставок сотрудников.
CREATE OR REPLACE PROCEDURE public.update_employees_rate(p_changes json)
LANGUAGE plpgsql
AS $$
DECLARE
    _change json;
    _employee_id uuid;
    _percent numeric;
BEGIN
    IF p_changes IS NULL OR json_typeof(p_changes) <> 'array' THEN
        RAISE EXCEPTION 'Expected a JSON array';
    END IF;

    FOR _change IN SELECT value FROM json_array_elements(p_changes)
    LOOP
        _employee_id := (_change->>'employee_id')::uuid;
        _percent := (_change->>'rate_change')::numeric;
        IF _employee_id IS NULL OR _percent IS NULL THEN
            RAISE EXCEPTION 'employee_id and rate_change are required';
        END IF;

        UPDATE public.employees AS e
        SET rate = GREATEST(500, ROUND(e.rate * (1 + _percent / 100)))::integer
        WHERE e.id = _employee_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Employee not found: %', _employee_id;
        END IF;
    END LOOP;
END;
$$;

-- 2. Индексация относительно средней ставки до изменения.
CREATE OR REPLACE PROCEDURE public.indexing_salary(p integer)
LANGUAGE plpgsql
AS $$
DECLARE
    _average_rate numeric;
BEGIN
    IF p IS NULL OR p < 0 THEN
        RAISE EXCEPTION 'Indexation percentage must be non-negative';
    END IF;

    SELECT AVG(e.rate) INTO _average_rate FROM public.employees AS e;
    UPDATE public.employees AS e
    SET rate = ROUND(e.rate * (
        1 + (p::numeric + CASE WHEN e.rate < _average_rate THEN 2 ELSE 0 END) / 100
    ))::integer;
END;
$$;

-- 3. Закрытие проекта и начисление бонусных часов.
CREATE OR REPLACE PROCEDURE public.close_project(p_project_id uuid)
LANGUAGE plpgsql
AS $$
DECLARE
    _project public.projects%ROWTYPE;
    _worked_hours bigint;
    _workers bigint;
    _bonus integer;
BEGIN
    SELECT p.* INTO _project
    FROM public.projects AS p
    WHERE p.id = p_project_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Project not found: %', p_project_id;
    END IF;
    IF NOT _project.is_active THEN
        RAISE EXCEPTION 'Project closed';
    END IF;

    SELECT COALESCE(SUM(l.work_hours), 0), COUNT(DISTINCT l.employee_id)
    INTO _worked_hours, _workers
    FROM public.logs AS l
    WHERE l.project_id = p_project_id;

    IF _workers > 0 AND _worked_hours > 0
       AND _project.estimated_time > _worked_hours THEN
        _bonus := LEAST(16, FLOOR(
            (_project.estimated_time::numeric - _worked_hours) * 0.75 / _workers
        ))::integer;

        IF _bonus > 0 THEN
            INSERT INTO public.logs(employee_id, project_id, work_date, work_hours)
            SELECT DISTINCT l.employee_id, p_project_id, CURRENT_DATE, _bonus
            FROM public.logs AS l
            WHERE l.project_id = p_project_id;
        END IF;
    END IF;

    UPDATE public.projects SET is_active = false WHERE id = p_project_id;
END;
$$;

-- 4. Регистрация рабочих часов.
CREATE OR REPLACE PROCEDURE public.log_work(
    p_employee_id uuid, p_project_id uuid, p_work_date date, p_work_hours integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    _is_active boolean;
    _day_hours bigint;
BEGIN
    SELECT p.is_active INTO _is_active
    FROM public.projects AS p
    WHERE p.id = p_project_id
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Project not found: %', p_project_id;
    END IF;
    IF NOT _is_active THEN
        RAISE EXCEPTION 'Project closed';
    END IF;
    IF p_work_hours IS NULL OR p_work_hours NOT BETWEEN 1 AND 24 THEN
        RAISE WARNING 'Invalid work hours: %, expected 1..24', p_work_hours;
        RETURN;
    END IF;
    IF p_work_date IS NULL THEN
        RAISE EXCEPTION 'Work date is required';
    END IF;

    -- Сериализация записей одного сотрудника для проверки дневной суммы.
    PERFORM 1 FROM public.employees AS e
    WHERE e.id = p_employee_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee not found: %', p_employee_id;
    END IF;

    SELECT COALESCE(SUM(l.work_hours), 0) INTO _day_hours
    FROM public.logs AS l
    WHERE l.employee_id = p_employee_id AND l.work_date = p_work_date;

    INSERT INTO public.logs(
        employee_id, project_id, work_date, work_hours, required_review
    ) VALUES (
        p_employee_id, p_project_id, p_work_date, p_work_hours,
        _day_hours + p_work_hours > 16
        OR p_work_date > CURRENT_DATE
        OR p_work_date < CURRENT_DATE - 7
    );
END;
$$;

-- 5. История ставок, включая исходные значения.
CREATE TABLE IF NOT EXISTS public.employee_rate_history (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id uuid NOT NULL REFERENCES public.employees(id),
    rate integer NOT NULL CHECK (rate > 0),
    from_date date NOT NULL
);

INSERT INTO public.employee_rate_history(employee_id, rate, from_date)
SELECT e.id, e.rate, DATE '2020-12-26'
FROM public.employees AS e
WHERE NOT EXISTS (
    SELECT 1 FROM public.employee_rate_history AS h WHERE h.employee_id = e.id
);

CREATE OR REPLACE FUNCTION public.save_employee_rate_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' OR OLD.rate IS DISTINCT FROM NEW.rate THEN
        INSERT INTO public.employee_rate_history(employee_id, rate, from_date)
        VALUES (NEW.id, NEW.rate, CURRENT_DATE);
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER change_employee_rate
AFTER INSERT OR UPDATE OF rate ON public.employees
FOR EACH ROW EXECUTE FUNCTION public.save_employee_rate_history();

-- 6 и 6*. Лучшие сотрудники; при равенстве учитываются дни работы.
CREATE OR REPLACE FUNCTION public.best_project_workers(p_project_id uuid)
RETURNS TABLE(employee text, work_hours bigint)
LANGUAGE sql
AS $$
    SELECT e.name, SUM(l.work_hours) AS total_hours
    FROM public.logs AS l
    JOIN public.employees AS e ON e.id = l.employee_id
    WHERE l.project_id = p_project_id
    GROUP BY e.id, e.name
    ORDER BY total_hours DESC, COUNT(DISTINCT l.work_date) DESC, RANDOM()
    LIMIT 3;
$$;

-- 7 и 7*. Расчёт по текущей ставке с предупреждением о непроверенных часах.
CREATE OR REPLACE FUNCTION public.calculate_month_salary(
    p_from_date date, p_to_date date
)
RETURNS TABLE(id uuid, employee text, worked_hours bigint, salary numeric)
LANGUAGE plpgsql
AS $$
DECLARE
    _employee record;
BEGIN
    IF p_from_date IS NULL OR p_to_date IS NULL OR p_from_date > p_to_date THEN
        RAISE EXCEPTION 'Invalid salary period';
    END IF;

    FOR _employee IN
        SELECT DISTINCT e.id, e.name
        FROM public.employees AS e
        JOIN public.logs AS l ON l.employee_id = e.id
        WHERE l.work_date BETWEEN p_from_date AND p_to_date
          AND l.required_review AND NOT l.is_paid
    LOOP
        RAISE WARNING 'Warning! Employee % hours must be reviewed!', _employee.name;
    END LOOP;

    RETURN QUERY
    WITH hours AS (
        SELECT l.employee_id, SUM(l.work_hours) AS total_hours
        FROM public.logs AS l
        WHERE l.work_date BETWEEN p_from_date AND p_to_date
          AND NOT l.required_review AND NOT l.is_paid
        GROUP BY l.employee_id
    )
    SELECT e.id, e.name, h.total_hours,
           ROUND(e.rate::numeric * (
               LEAST(h.total_hours, 160)
               + GREATEST(h.total_hours - 160, 0) * 1.25
           ), 2)
    FROM hours AS h
    JOIN public.employees AS e ON e.id = h.employee_id
    ORDER BY e.name, e.id;
END;
$$;

COMMIT;
