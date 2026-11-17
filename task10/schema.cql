-- Схема Cassandra для критически важных данных «Мобильного мира».
-- Описание и обоснование — в README.md.
--
-- Два дата-центра (по регионам), в каждом по 3 реплики. Для одноузлового стенда
-- замените 'msk': 3, 'ekb': 3 на 'datacenter1': 1.

CREATE KEYSPACE IF NOT EXISTS shop
  WITH replication = { 'class': 'NetworkTopologyStrategy', 'msk': 3, 'ekb': 3 }
  AND durable_writes = true;

USE shop;

-- Позиция заказа (вложенная структура в истории заказов)
CREATE TYPE IF NOT EXISTS order_item (
  product_id uuid,
  name       text,
  category   text,
  price      decimal,
  quantity   int
);

-- ---------------------------------------------------------------------------
-- 1. Корзины: одна партиция на владельца корзины, одна строка на товар
--    owner_id = 'u:<user_id>' для пользователя, 's:<session_id>' для гостя
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS carts_by_owner (
  owner_id    text,
  product_id  uuid,
  quantity    int,
  added_at    timestamp,
  cart_id     uuid      STATIC,   -- общие для всей корзины поля
  user_id     text      STATIC,
  session_id  text      STATIC,
  created_at  timestamp STATIC,
  updated_at  timestamp STATIC,
  PRIMARY KEY ((owner_id), product_id)
) WITH default_time_to_live = 604800          -- 7 дней; каждая запись продлевает срок
  AND gc_grace_seconds = 172800               -- 2 дня: repair корзин выполняется ежедневно
  AND compaction = { 'class': 'SizeTieredCompactionStrategy' }
  AND read_repair = 'BLOCKING'
  AND comment = 'Активные корзины гостей и пользователей';

-- ---------------------------------------------------------------------------
-- 2. Пользовательские сессии
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sessions (
  session_id  text,
  user_id     text,
  created_at  timestamp,
  last_seen   timestamp,
  revoked     boolean,                -- выход: флаг вместо удаления, без tombstone
  geo_zone    text,
  attributes  map<text, text>,        -- язык, регион доставки, A/B-группа и т. п.
  PRIMARY KEY ((session_id))
) WITH default_time_to_live = 1800            -- 30 минут; каждое обращение продлевает срок
  AND gc_grace_seconds = 3600                 -- данные только с TTL, явных удалений нет
  AND compaction = { 'class': 'TimeWindowCompactionStrategy',
                     'compaction_window_unit': 'HOURS', 'compaction_window_size': 1 }
  AND read_repair = 'NONE'
  AND comment = 'Сессии пользователей и гостей';

-- Сессии пользователя: «выйти на всех устройствах», ограничение числа сессий
CREATE TABLE IF NOT EXISTS sessions_by_user (
  user_id     text,
  session_id  text,
  created_at  timestamp,
  last_seen   timestamp,
  user_agent  text,
  PRIMARY KEY ((user_id), session_id)
) WITH default_time_to_live = 1800
  AND gc_grace_seconds = 3600
  AND compaction = { 'class': 'TimeWindowCompactionStrategy',
                     'compaction_window_unit': 'HOURS', 'compaction_window_size': 1 }
  AND read_repair = 'NONE';

-- ---------------------------------------------------------------------------
-- 3. История заказов пользователя: партиция = пользователь + год
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS orders_by_customer (
  customer_id  text,
  year         smallint,
  created_at   timestamp,
  order_id     uuid,
  status       text,
  total        decimal,
  geo_zone     text,
  items        frozen<list<frozen<order_item>>>,
  updated_at   timestamp,
  PRIMARY KEY ((customer_id, year), created_at, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC, order_id ASC)
  AND gc_grace_seconds = 864000               -- 10 дней (по умолчанию)
  AND compaction = { 'class': 'LeveledCompactionStrategy' }
  AND read_repair = 'BLOCKING'
  AND comment = 'История заказов клиента, новые сверху';

-- ---------------------------------------------------------------------------
-- 4. Текущий статус заказа по его идентификатору
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS order_status (
  order_id     uuid,
  customer_id  text,
  created_at   timestamp,
  status       text,
  total        decimal,
  updated_at   timestamp,
  PRIMARY KEY ((order_id))
) WITH gc_grace_seconds = 864000
  AND compaction = { 'class': 'LeveledCompactionStrategy' }
  AND read_repair = 'BLOCKING'
  AND comment = 'Статус заказа: страница заказа, служба поддержки';

-- ---------------------------------------------------------------------------
-- 5. История изменений статуса заказа (только добавление)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS order_status_history (
  order_id    uuid,
  changed_at  timeuuid,
  status      text,
  source      text,                   -- payment, warehouse, delivery, support
  comment     text,
  PRIMARY KEY ((order_id), changed_at)
) WITH CLUSTERING ORDER BY (changed_at DESC)
  AND gc_grace_seconds = 864000
  AND compaction = { 'class': 'LeveledCompactionStrategy' }
  AND read_repair = 'BLOCKING'
  AND comment = 'Журнал смены статусов заказа';
