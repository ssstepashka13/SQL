CREATE TABLE catalog.cities (
    id   serial PRIMARY KEY,
    name text NOT NULL UNIQUE
);

-- список городов, который раньше жил в коде (warehouses.py)
INSERT INTO catalog.cities (name) VALUES
    ('Москва'),
    ('Санкт-Петербург'),
    ('Новосибирск'),
    ('Екатеринбург'),
    ('Казань'),
    ('Нижний Новгород'),
    ('Челябинск'),
    ('Самара'),
    ('Омск'),
    ('Ростов-на-Дону'),
    ('Уфа'),
    ('Красноярск'),
    ('Воронеж'),
    ('Пермь'),
    ('Волгоград');

-- на случай, если в складах встречается город не из списка
INSERT INTO catalog.cities (name)
SELECT DISTINCT city FROM catalog.warehouses
ON CONFLICT (name) DO NOTHING;

-- склад теперь ссылается на город, старая текстовая колонка заполняет новую
ALTER TABLE catalog.warehouses
    ADD COLUMN city_id integer REFERENCES catalog.cities (id);

UPDATE catalog.warehouses w
SET city_id = c.id
FROM catalog.cities c
WHERE c.name = w.city;

ALTER TABLE catalog.warehouses
    ALTER COLUMN city_id SET NOT NULL;

ALTER TABLE catalog.warehouses DROP COLUMN city;
