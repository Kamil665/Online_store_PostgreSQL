-- ============================================================
-- ПРОЕКТ: ИНТЕРНЕТ-МАГАЗИН
-- PostgreSQL
-- Автор: Камиль
-- ============================================================


-- ============================================================
-- БЛОК 1. СХЕМА БАЗЫ ДАННЫХ (DDL)
-- ============================================================

CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    имя VARCHAR(100) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);


CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    название VARCHAR(200) NOT NULL,
    цена NUMERIC(10, 2) CHECK (цена >= 0),
    остаток INT DEFAULT 0 CHECK (остаток >= 0)
);


CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES users(id),
    статус VARCHAR(20) DEFAULT 'new',
    created_at TIMESTAMP DEFAULT NOW()
);


CREATE TABLE order_items (
    order_id INT REFERENCES orders(id) ON DELETE CASCADE,
    product_id INT REFERENCES products(id),
    количество INT CHECK (количество > 0),

    PRIMARY KEY (order_id, product_id)
);


-- ============================================================
-- БЛОК 2. ИНДЕКСЫ
-- ============================================================

CREATE INDEX idx_orders_user
ON orders(user_id);


CREATE INDEX idx_items_product
ON order_items(product_id);


CREATE INDEX idx_products_name
ON products
USING GIN (to_tsvector('russian', название));


-- ============================================================
-- БЛОК 3. ФУНКЦИИ
-- ============================================================

CREATE OR REPLACE FUNCTION order_total(p_order_id INT)
RETURNS NUMERIC
LANGUAGE SQL
AS $$
    SELECT COALESCE(
        SUM(oi.количество * p.цена),
        0
    )
    FROM order_items oi
    JOIN products p
        ON oi.product_id = p.id
    WHERE oi.order_id = p_order_id;
$$;


CREATE OR REPLACE FUNCTION остаток_товара(p_product_id INT)
RETURNS INT
LANGUAGE SQL
AS $$
    SELECT остаток
    FROM products
    WHERE id = p_product_id;
$$;


CREATE OR REPLACE FUNCTION check_stock()
RETURNS TRIGGER
LANGUAGE PLPGSQL
AS $$
DECLARE
    current_stock INT;
BEGIN

    SELECT остаток
    INTO current_stock
    FROM products
    WHERE id = NEW.product_id
    FOR UPDATE;


    IF current_stock IS NULL THEN
        RAISE EXCEPTION
            'Товар с ID % не найден',
            NEW.product_id;
    END IF;


    IF NEW.количество > current_stock THEN
        RAISE EXCEPTION
            'Недостаточно товара на складе. Доступно: %, запрошено: %',
            current_stock,
            NEW.количество;
    END IF;


    UPDATE products
    SET остаток = остаток - NEW.количество
    WHERE id = NEW.product_id;


    RETURN NEW;

END;
$$;


-- ============================================================
-- БЛОК 4. ТРИГГЕРЫ
-- ============================================================

CREATE TRIGGER trg_check_stock
BEFORE INSERT
ON order_items
FOR EACH ROW
EXECUTE FUNCTION check_stock();


-- ============================================================
-- БЛОК 5. ХРАНИМАЯ ПРОЦЕДУРА
-- ============================================================

CREATE TYPE order_item_type AS (
    product_id INT,
    количество INT
);


CREATE OR REPLACE PROCEDURE create_order(
    p_user_id INT,
    p_items order_item_type[]
)
LANGUAGE PLPGSQL
AS $$
DECLARE
    new_order_id INT;
    item order_item_type;
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
    ) THEN
        RAISE EXCEPTION
            'Пользователь с ID % не найден',
            p_user_id;
    END IF;


    INSERT INTO orders (
        user_id,
        статус
    )
    VALUES (
        p_user_id,
        'new'
    )
    RETURNING id INTO new_order_id;


    FOREACH item IN ARRAY p_items
    LOOP

        INSERT INTO order_items (
            order_id,
            product_id,
            количество
        )
        VALUES (
            new_order_id,
            item.product_id,
            item.количество
        );

    END LOOP;


    RAISE NOTICE
        'Заказ №% успешно создан',
        new_order_id;

END;
$$;


-- ============================================================
-- БЛОК 6. ПРЕДСТАВЛЕНИЯ
-- ============================================================

CREATE OR REPLACE VIEW top_customers AS
SELECT
    u.имя,
    COUNT(o.id) AS число_заказов,
    COALESCE(
        SUM(order_total(o.id)),
        0
    ) AS общая_сумма
FROM users u
JOIN orders o
    ON o.user_id = u.id
GROUP BY
    u.id,
    u.имя
ORDER BY
    общая_сумма DESC
LIMIT 10;


-- ============================================================
-- БЛОК 7. ТИПОВЫЕ ЗАПРОСЫ
-- ============================================================

-- Заказы пользователя

-- SELECT
--     o.id,
--     o.статус,
--     order_total(o.id) AS сумма
-- FROM orders o
-- WHERE o.user_id = 1
-- ORDER BY o.created_at DESC;


-- Товары с малым остатком

-- SELECT
--     id,
--     название,
--     цена,
--     остаток
-- FROM products
-- WHERE остаток < 10
-- ORDER BY остаток ASC;


-- Отчёт по продажам за текущий месяц

-- SELECT
--     p.название,
--     SUM(oi.количество) AS продано
-- FROM order_items oi
-- JOIN products p
--     ON p.id = oi.product_id
-- JOIN orders o
--     ON o.id = oi.order_id
-- WHERE o.created_at >= DATE_TRUNC('month', NOW())
-- GROUP BY
--     p.id,
--     p.название
-- ORDER BY
--     продано DESC;


-- Топ покупателей

-- SELECT *
-- FROM top_customers;


-- Все товары

-- SELECT *
-- FROM products;


-- Все пользователи

-- SELECT *
-- FROM users;


-- ============================================================
-- БЛОК 8. УПРАВЛЕНИЕ ДОСТУПОМ
-- ============================================================

-- Создание ролей требует прав CREATEROLE.
-- Поэтому эти команды оставлены закомментированными.

-- CREATE ROLE app_user;

-- GRANT SELECT, INSERT, UPDATE
-- ON users, orders, order_items
-- TO app_user;

-- GRANT USAGE, SELECT
-- ON ALL SEQUENCES
-- IN SCHEMA public
-- TO app_user;


-- Роль только для чтения

-- CREATE ROLE readonly;

-- GRANT SELECT
-- ON ALL TABLES
-- IN SCHEMA public
-- TO readonly;


-- ============================================================
-- RLS
-- ============================================================

ALTER TABLE orders
ENABLE ROW LEVEL SECURITY;


CREATE OR REPLACE FUNCTION current_user_id()
RETURNS INT
LANGUAGE SQL
AS $$
    SELECT NULLIF(
        current_setting(
            'app.current_user_id',
            true
        ),
        ''
    )::INT;
$$;


CREATE POLICY own_orders
ON orders
USING (
    user_id = current_user_id()
);


-- ============================================================
-- БЛОК 9. РЕЗЕРВНОЕ КОПИРОВАНИЕ
-- ============================================================

-- Создание резервной копии:
--
-- pg_dump -Fc mydb > backup.dump


-- Восстановление:
--
-- pg_restore -d mydb backup.dump


-- ============================================================
-- БЛОК 10. ТЕСТОВЫЕ ДАННЫЕ
-- ============================================================


-- ============================================================
-- 10.1. ПОЛЬЗОВАТЕЛИ
-- ============================================================

INSERT INTO users (email, имя)
VALUES
    ('kamil@gmail.com', 'Камиль'),
    ('ivan@gmail.com', 'Иван'),
    ('sasha@gmail.com', 'Саша'),
    ('anna@gmail.com', 'Анна'),
    ('dmitry@gmail.com', 'Дмитрий'),
    ('elena@gmail.com', 'Елена'),
    ('maxim@gmail.com', 'Максим'),
    ('olga@gmail.com', 'Ольга'),
    ('nikita@gmail.com', 'Никита'),
    ('maria@gmail.com', 'Мария'),
    ('alex@gmail.com', 'Алексей'),
    ('sofia@gmail.com', 'София');


-- ============================================================
-- 10.2. ТОВАРЫ
-- ============================================================

INSERT INTO products (
    название,
    цена,
    остаток
)
VALUES
    ('Ноутбук ASUS VivoBook', 75000.00, 15),
    ('Ноутбук Lenovo IdeaPad', 68000.00, 12),
    ('iPhone 15', 85000.00, 10),
    ('Samsung Galaxy S24', 72000.00, 14),
    ('Xiaomi Redmi Note 13', 28000.00, 25),
    ('Клавиатура Logitech K380', 4500.00, 30),
    ('Мышь Logitech G102', 2500.00, 40),
    ('Игровая мышь Razer', 6500.00, 18),
    ('Наушники Sony WH-1000XM5', 32000.00, 7),
    ('Наушники AirPods Pro', 26000.00, 9),
    ('Монитор Samsung 27"', 35000.00, 11),
    ('Монитор LG UltraGear', 42000.00, 8),
    ('Веб-камера Logitech C920', 8500.00, 20),
    ('Микрофон HyperX SoloCast', 9500.00, 13),
    ('SSD Samsung 1TB', 9000.00, 16),
    ('HDD Seagate 2TB', 7000.00, 22),
    ('Оперативная память Kingston 16GB', 5000.00, 19),
    ('Видеокарта RTX 4060', 38000.00, 6),
    ('Видеокарта RTX 4070', 65000.00, 5),
    ('Игровое кресло', 28000.00, 10);


-- ============================================================
-- 10.3. ЗАКАЗЫ
-- ============================================================

CALL create_order(
    1,
    ARRAY[
        ROW(1, 1)::order_item_type,
        ROW(6, 1)::order_item_type,
        ROW(7, 2)::order_item_type
    ]
);


CALL create_order(
    2,
    ARRAY[
        ROW(3, 1)::order_item_type,
        ROW(10, 1)::order_item_type
    ]
);


CALL create_order(
    3,
    ARRAY[
        ROW(5, 2)::order_item_type,
        ROW(7, 1)::order_item_type,
        ROW(13, 1)::order_item_type
    ]
);


CALL create_order(
    4,
    ARRAY[
        ROW(9, 1)::order_item_type,
        ROW(14, 1)::order_item_type
    ]
);


CALL create_order(
    5,
    ARRAY[
        ROW(18, 1)::order_item_type,
        ROW(17, 2)::order_item_type
    ]
);


CALL create_order(
    6,
    ARRAY[
        ROW(11, 1)::order_item_type,
        ROW(13, 1)::order_item_type,
        ROW(15, 1)::order_item_type
    ]
);


CALL create_order(
    7,
    ARRAY[
        ROW(2, 1)::order_item_type,
        ROW(8, 1)::order_item_type
    ]
);


CALL create_order(
    8,
    ARRAY[
        ROW(4, 1)::order_item_type,
        ROW(6, 2)::order_item_type,
        ROW(7, 1)::order_item_type
    ]
);


CALL create_order(
    9,
    ARRAY[
        ROW(19, 1)::order_item_type,
        ROW(20, 1)::order_item_type
    ]
);


CALL create_order(
    10,
    ARRAY[
        ROW(12, 1)::order_item_type,
        ROW(16, 1)::order_item_type
    ]
);


CALL create_order(
    11,
    ARRAY[
        ROW(1, 1)::order_item_type,
        ROW(15, 1)::order_item_type,
        ROW(17, 1)::order_item_type
    ]
);


CALL create_order(
    12,
    ARRAY[
        ROW(10, 1)::order_item_type,
        ROW(13, 1)::order_item_type
    ]
);


CALL create_order(
    1,
    ARRAY[
        ROW(3, 1)::order_item_type,
        ROW(9, 1)::order_item_type
    ]
);


CALL create_order(
    1,
    ARRAY[
        ROW(11, 1)::order_item_type,
        ROW(14, 1)::order_item_type
    ]
);


CALL create_order(
    2,
    ARRAY[
        ROW(18, 1)::order_item_type,
        ROW(7, 1)::order_item_type
    ]
);


-- ============================================================
-- БЛОК 11. ПРОВЕРКА ДАННЫХ
-- ============================================================


-- Все пользователи

SELECT
    id,
    email,
    имя,
    created_at
FROM users
ORDER BY id;


-- Все товары

SELECT
    id,
    название,
    цена,
    остаток
FROM products
ORDER BY id;


-- Все заказы

SELECT
    o.id AS номер_заказа,
    u.имя AS покупатель,
    o.статус,
    o.created_at,
    order_total(o.id) AS сумма
FROM orders o
JOIN users u
    ON u.id = o.user_id
ORDER BY o.id;


-- ============================================================
-- БЛОК 12. ПОДРОБНЫЙ СПИСОК ЗАКАЗОВ
-- ============================================================

SELECT
    o.id AS заказ,
    u.имя AS покупатель,
    p.название AS товар,
    oi.количество,
    p.цена,
    oi.количество * p.цена AS стоимость
FROM order_items oi
JOIN orders o
    ON o.id = oi.order_id
JOIN users u
    ON u.id = o.user_id
JOIN products p
    ON p.id = oi.product_id
ORDER BY o.id;


-- ============================================================
-- БЛОК 13. TOP CUSTOMERS
-- ============================================================

SELECT *
FROM top_customers;


-- ============================================================
-- БЛОК 14. ТОВАРЫ С МАЛЫМ ОСТАТКОМ
-- ============================================================

SELECT
    id,
    название,
    цена,
    остаток
FROM products
WHERE остаток < 10
ORDER BY остаток ASC;


-- ============================================================
-- БЛОК 15. ПРОДАЖИ ЗА МЕСЯЦ
-- ============================================================

SELECT
    p.название,
    SUM(oi.количество) AS продано
FROM order_items oi
JOIN products p
    ON p.id = oi.product_id
JOIN orders o
    ON o.id = oi.order_id
WHERE o.created_at >= DATE_TRUNC('month', NOW())
GROUP BY
    p.id,
    p.название
ORDER BY
    продано DESC;


-- ============================================================
-- КОНЕЦ ПРОЕКТА
-- ============================================================
