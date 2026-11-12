# Задание 7. Схемы коллекций и шардирование данных «Мобильного мира»

## 1. Контекст и исходные требования

Данные магазина хранятся в шардированном кластере MongoDB (схемы 1–5): `mongos_router`, конфиг-сервер и шарды,
каждый шард — replica set из трёх узлов. База — `shop`, коллекции — `orders`, `products`, `carts`.

| Коллекция | Основные операции | Что важнее всего |
|---|---|---|
| `orders` | создание заказа со списанием остатков; история заказов пользователя; статус заказа | быстрая запись, чтение по пользователю |
| `products` | частое обновление остатков; поиск по категории и диапазону цен; карточка товара | точечная запись по товару, чтение каталога |
| `carts` | создание; получение активной корзины по `session_id` или `user_id`; изменение товаров; слияние гостевой корзины в пользовательскую; отметка «заказана» | все операции — над одной корзиной конкретного владельца |

Критерии выбора шард-ключа:

1. **Кардинальность** — у ключа много различных значений, чтобы данные можно было разбить на много чанков.
2. **Равномерность** — значения распределены без перекоса, нет «горячего» шарда.
3. **Немонотонность** — новые документы не попадают всегда в последний чанк (как при ключе по дате или `ObjectId`).
4. **Адресность запросов** — частые операции содержат шард-ключ в фильтре и уходят на один шард,
   а не рассылаются на все (scatter-gather).

## 2. Итоговое решение

| Коллекция | Шард-ключ | Стратегия | Адресные операции |
|---|---|---|---|
| `orders` | `{ customer_id: "hashed" }` | хешированное шардирование | создание заказа, история пользователя, статус заказа (с `customer_id`) |
| `products` | `{ _id: "hashed" }` | хешированное шардирование | обновление остатков, карточка товара |
| `carts` | `{ owner_id: "hashed" }` | хешированное шардирование | все операции с корзиной, включая слияние |

Поиск товаров по категории — единственная частая операция, которая идёт на все шарды. Почему это приемлемо и как
это компенсируется — в разделе 4.4.

---

## 3. Коллекция `orders`

### 3.1. Схема документа

```javascript
{
  _id: ObjectId("6750a1f2c3d4e5f6a7b8c9d0"),   // уникальный идентификатор заказа
  customer_id: "c-102938",                      // идентификатор клиента
  created_at: ISODate("2026-11-27T10:15:00Z"),  // дата и время оформления
  items: [                                      // заказанные товары и цена на момент заказа
    { product_id: ObjectId("..."), name: "Смартфон X", category: "electronics", price: NumberDecimal("59990.00"), quantity: 1 },
    { product_id: ObjectId("..."), name: "Книга «Чистая архитектура»", category: "books", price: NumberDecimal("1290.00"), quantity: 2 }
  ],
  status: "created",                            // created | paid | shipped | delivered | cancelled
  total: NumberDecimal("62570.00"),             // общая сумма заказа
  geo_zone: "msk"                               // геозона заказа
}
```

Цена и название товара копируются в заказ: заказ должен хранить цену на момент покупки,
а не текущую цену из `products`.

### 3.2. Кандидаты в шард-ключи

| Кандидат | Кардинальность | Распределение | Адресность | Вывод |
|---|---|---|---|---|
| `_id` (ObjectId) | высокая | монотонный рост — все вставки в последний чанк, горячий шард | только статус по `_id`; история пользователя — на все шарды | ❌ |
| `created_at` | высокая | монотонный — та же проблема горячего шарда | запросы по пользователю не адресные | ❌ |
| `geo_zone` | низкая (десятки зон) | сильный перекос: Москва в разы больше остальных; чанки по одной зоне неделимы (jumbo) | история пользователя не адресная | ❌ как самостоятельный ключ |
| `status` | очень низкая (5 значений) | перекос, значение меняется у документа | — | ❌ |
| `customer_id` (диапазонный) | высокая | при последовательной выдаче идентификаторов новые клиенты попадают в один чанк | история и статус — адресные | ⚠️ |
| **`customer_id` (хешированный)** | высокая | равномерное по хешу, независимо от формата идентификатора | история и статус — адресные (равенство по `customer_id`) | ✅ |

### 3.3. Выбор: `{ customer_id: "hashed" }`

- **Создание заказа** — запись идёт на один шард. Заказы разных клиентов равномерно распределяются по всем шардам,
  поэтому пиковая нагрузка «чёрной пятницы» делится между шардами, а не ложится на последний чанк, как было бы
  при ключе по `_id` или `created_at`.
- **История заказов пользователя** — фильтр `{ customer_id }` содержит шард-ключ, запрос уходит на один шард.
  Внутри шарда сортировку по дате обслуживает индекс `{ customer_id: 1, created_at: -1 }`.
- **Статус заказа** — пользователь смотрит свои заказы, поэтому `customer_id` известен из сессии.
  Запрос `{ _id, customer_id }` — адресный. Поиск только по `_id` (например, из службы поддержки) пойдёт на все шарды,
  но это редкая операция, и её обслуживает индекс по `_id` на каждом шарде.
- Один клиент не может создать перекос: даже у самого активного покупателя заказов несравнимо меньше,
  чем умещается в чанке.

Геозона не входит в шард-ключ, но по ней можно сделать **зонное шардирование** в будущем, если шарды будут
размещены в разных регионах. Тогда ключ станет составным — `{ geo_zone: 1, customer_id: "hashed" }`, — и заказы
каждого региона будут храниться на шардах этого региона.

### 3.4. Создание заказа со списанием остатков

Заказ и остатки лежат в разных коллекциях и, как правило, на разных шардах. Чтобы заказ не был создан без списания
остатков (и наоборот), обе операции выполняются в **распределённой транзакции** (MongoDB 4.2+).
Списание — условное: `$inc` срабатывает, только если остатка хватает, иначе транзакция откатывается.

```javascript
const session = db.getMongo().startSession();
const shop = session.getDatabase("shop");
session.startTransaction({ readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } });
try {
  const items = [{ product_id: productId, name: "Смартфон X", category: "electronics", price: NumberDecimal("59990.00"), quantity: 1 }];
  for (const item of items) {
    const res = shop.products.updateOne(
      { _id: item.product_id, "stock.msk": { $gte: item.quantity } },   // адресно: шард-ключ products — _id
      { $inc: { "stock.msk": -item.quantity } }
    );
    if (res.modifiedCount !== 1) throw new Error("Недостаточно товара " + item.product_id);
  }
  shop.orders.insertOne({                                              // адресно: шард-ключ orders — customer_id
    customer_id: "c-102938", created_at: new Date(), items: items,
    status: "created", total: NumberDecimal("59990.00"), geo_zone: "msk"
  });
  session.commitTransaction();
} catch (e) {
  session.abortTransaction();
  throw e;
} finally {
  session.endSession();
}
```

Каждая операция в транзакции адресная, поэтому транзакция затрагивает только нужные шарды
(шард заказа и шарды товаров), а не весь кластер.

---

## 4. Коллекция `products`

### 4.1. Схема документа

```javascript
{
  _id: ObjectId("6750a1f2c3d4e5f6a7b8c9d1"),   // уникальный идентификатор товара
  name: "Смартфон X",                           // наименование
  category: "electronics",                      // категория
  price: NumberDecimal("59990.00"),             // цена
  stock: {                                      // остаток в каждой геозоне
    ekb: 50,
    kgd: 30,
    msk: 120
  },
  attributes: {                                 // дополнительные атрибуты
    color: "black",
    size: "6.1\""
  }
}
```

Остатки хранятся во вложенном объекте `stock` с ключом по геозоне. Так остаток в любой зоне меняется одной атомарной
операцией `$inc` над одним документом, без транзакций и без отдельной коллекции остатков.

### 4.2. Кандидаты в шард-ключи

| Кандидат | Кардинальность | Распределение | Адресность | Вывод |
|---|---|---|---|---|
| `category` | низкая (десятки категорий) | перекос: «Электроника» больше «Книг»; чанк одной категории не делится (jumbo); на распродаже горячая категория — горячий шард | поиск по категории — адресный; карточка и списание остатков по `_id` — на все шарды | ❌ |
| `price` | средняя | значение меняется; перекос по ценовым диапазонам | только фильтр по цене | ❌ |
| `{ category: 1, _id: 1 }` | высокая | внутри категории `_id` монотонен — новые товары в последний чанк категории | поиск по категории — адресный; карточка и остатки адресные, только если в каждом запросе известна категория | ⚠️ |
| `_id` (диапазонный) | высокая | монотонный — новые товары в последний чанк | карточка и остатки — адресные | ⚠️ |
| **`_id` (хешированный)** | высокая | равномерное | карточка и остатки — адресные | ✅ |

### 4.3. Выбор: `{ _id: "hashed" }`

- **Обновление остатков** — самая частая запись в `products`: при каждой покупке. Фильтр `{ _id }` содержит
  шард-ключ, обновление идёт на один шард. Популярные товары распределены по хешу между всеми шардами,
  поэтому распродажа не создаёт горячего шарда.
- **Карточка товара** — `findOne({ _id })`, адресный запрос.
- Новые товары распределяются по всем шардам, а не дописываются в последний чанк.

Составной ключ `{ category: 1, _id: 1 }` сделал бы адресным поиск по категории, но тогда каждое списание остатков
и каждый показ карточки должны знать категорию товара. В корзине (`items: { product_id, quantity }`) и в ссылках
на товар категории нет, поэтому самые частые операции стали бы рассылаться на все шарды. Кроме того, все товары
горячей категории оказались бы в небольшом числе чанков.

### 4.4. Поиск по категории и цене

Запрос `{ category, price: { $gte, $lte } }` при ключе `{ _id: "hashed" }` уходит на все шарды. Это приемлемо:

- на каждом шарде запрос обслуживается индексом `{ category: 1, price: 1 }`, шарды отвечают параллельно,
  а `mongos` объединяет результат;
- товаров на порядки меньше, чем заказов и корзин, — коллекция компактная, рабочий набор помещается в память;
- выдачу каталога кеширует приложение в Redis (схема 3), а статика страницы отдаётся через CDN (схема 5);
- чтение каталога допускает небольшую задержку, поэтому его можно направить на SECONDARY-реплики
  (`readPreference: "secondaryPreferred"`) и не нагружать PRIMARY, на которые идут списания остатков.

---

## 5. Коллекция `carts`

### 5.1. Схема документа

```javascript
{
  _id: ObjectId("6750a1f2c3d4e5f6a7b8c9d2"),   // уникальный идентификатор корзины
  owner_id: "s:9f8e7d6c",                       // шард-ключ: "u:<user_id>" или "s:<session_id>"
  user_id: null,                                // идентификатор пользователя (null у гостя)
  session_id: "9f8e7d6c",                       // идентификатор сессии гостя
  items: [                                      // товары в корзине
    { product_id: ObjectId("..."), quantity: 2 }
  ],
  status: "active",                             // active | ordered | abandoned
  created_at: ISODate("2026-11-27T10:00:00Z"),
  updated_at: ISODate("2026-11-27T10:05:00Z"),
  expires_at: ISODate("2026-12-04T10:05:00Z")   // TTL: корзина удаляется автоматически
}
```

Поле `owner_id` — производное: у пользователя `"u:" + user_id`, у гостя `"s:" + session_id`.
Оно заполняется при создании корзины и не меняется. Поля `user_id` и `session_id` остаются в документе как требуется.

### 5.2. Кандидаты в шард-ключи

| Кандидат | Кардинальность | Распределение | Адресность | Вывод |
|---|---|---|---|---|
| `_id` (хешированный) | высокая | равномерное | корзину ищут по `session_id` или `user_id`, а не по `_id` — все поиски на все шарды | ❌ |
| `user_id` | высокая у пользователей | у всех гостей `user_id = null` — все гостевые корзины в одном неделимом чанке (jumbo, горячий шард) | поиск гостевой корзины не адресный | ❌ |
| `session_id` | высокая | равномерное (хеш) | пользователь заходит с разных устройств и сессий — поиск по `user_id` не адресный | ❌ |
| `status` | 3 значения | перекос, значение меняется | — | ❌ |
| **`owner_id` (хешированный)** | высокая | равномерное | обе формы поиска (`session_id` и `user_id`) — адресные | ✅ |

### 5.3. Выбор: `{ owner_id: "hashed" }`

- **Получение активной корзины** — `{ owner_id: "s:<session_id>", status: "active" }` для гостя
  и `{ owner_id: "u:<user_id>", status: "active" }` для пользователя. Оба запроса адресные.
- **Создание, добавление, замена и удаление товара, отметка «заказана»** — операции над одной корзиной
  с `owner_id` в фильтре, каждая идёт на один шард.
- **Слияние корзин** — три адресные операции: прочитать гостевую корзину, добавить её товары в пользовательскую,
  отметить гостевую как `abandoned`. Шард-ключ ни у одной корзины не меняется: пользовательская корзина
  изначально имеет `owner_id: "u:..."`, гостевая остаётся с `"s:..."`.
- Хеш распределяет корзины, в том числе гостевые, равномерно, а их массовое создание на распродаже —
  по всем шардам.
- TTL-индекс по `expires_at` удаляет устаревшие корзины на каждом шарде независимо.
- Уникальный частичный индекс `{ owner_id: 1, status: 1 }` с условием `status: "active"` гарантирует,
  что у владельца не больше одной активной корзины. Такой уникальный индекс допустим в шардированной коллекции,
  потому что начинается с поля шард-ключа.

---

## 6. Команды MongoDB

Все команды выполняются через роутер:

```shell
docker compose exec -T mongos_router mongosh --port 27020
```

В примерах `productId` и `orderId` — идентификаторы существующих товара и заказа, например:
`const productId = db.products.findOne({ name: "Смартфон X" })._id`.

Все команды этого раздела и транзакция из раздела 3.4 проверены на кластере из задания 3
(MongoDB 9.0, два шарда по три реплики). Результаты `explain()`: поиск корзины по владельцу, истории заказов,
статуса заказа и карточки товара — `SINGLE_SHARD`; поиск товаров по категории — `SHARD_MERGE`.

### 6.1. Создание коллекций, индексов и шардирование

```javascript
use shop
sh.enableSharding("shop")

// ---------- orders ----------
db.createCollection("orders", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["customer_id", "created_at", "items", "status", "total", "geo_zone"],
    properties: {
      customer_id: { bsonType: "string" },
      created_at:  { bsonType: "date" },
      items: { bsonType: "array", minItems: 1, items: {
        bsonType: "object",
        required: ["product_id", "price", "quantity"],
        properties: {
          product_id: { bsonType: "objectId" },
          price:      { bsonType: "decimal" },
          quantity:   { bsonType: "number", minimum: 1 }
        }
      } },
      status:   { enum: ["created", "paid", "shipped", "delivered", "cancelled"] },
      total:    { bsonType: "decimal" },
      geo_zone: { bsonType: "string" }
    }
  } }
})
sh.shardCollection("shop.orders", { customer_id: "hashed" })
db.orders.createIndex({ customer_id: 1, created_at: -1 })   // история заказов пользователя

// ---------- products ----------
db.createCollection("products", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["name", "category", "price", "stock"],
    properties: {
      name:       { bsonType: "string" },
      category:   { bsonType: "string" },
      price:      { bsonType: "decimal" },
      stock:      { bsonType: "object", additionalProperties: { bsonType: "number", minimum: 0 } },
      attributes: { bsonType: "object" }
    }
  } }
})
sh.shardCollection("shop.products", { _id: "hashed" })
db.products.createIndex({ category: 1, price: 1 })          // поиск по категории и диапазону цен

// ---------- carts ----------
db.createCollection("carts", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["owner_id", "items", "status", "created_at", "updated_at", "expires_at"],
    properties: {
      owner_id:   { bsonType: "string", pattern: "^(u|s):" },
      user_id:    { bsonType: ["string", "null"] },
      session_id: { bsonType: ["string", "null"] },
      items: { bsonType: "array", items: {
        bsonType: "object",
        required: ["product_id", "quantity"],
        properties: {
          product_id: { bsonType: "objectId" },
          quantity:   { bsonType: "number", minimum: 1 }
        }
      } },
      status:     { enum: ["active", "ordered", "abandoned"] },
      created_at: { bsonType: "date" },
      updated_at: { bsonType: "date" },
      expires_at: { bsonType: "date" }
    }
  } }
})
sh.shardCollection("shop.carts", { owner_id: "hashed" })
db.carts.createIndex(                                       // не больше одной активной корзины у владельца
  { owner_id: 1, status: 1 },
  { unique: true, partialFilterExpression: { status: "active" } }
)
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 })   // TTL: удаление по expires_at
```

Остаток в схеме валидации — `minimum: 0`, поэтому даже ошибочное списание не уведёт его в минус:
такая запись будет отклонена.

### 6.2. Операции с `orders`

```javascript
// История заказов пользователя — адресный запрос
db.orders.find({ customer_id: "c-102938" }).sort({ created_at: -1 }).limit(20)

// Статус заказа — адресный запрос
db.orders.findOne({ _id: orderId, customer_id: "c-102938" }, { status: 1, total: 1, created_at: 1 })

// Смена статуса
db.orders.updateOne({ _id: orderId, customer_id: "c-102938" }, { $set: { status: "paid" } })
```

Создание заказа со списанием остатков — в разделе 3.4.

### 6.3. Операции с `products`

```javascript
// Карточка товара — адресный запрос
db.products.findOne({ _id: productId })

// Списание остатка при покупке — адресное условное обновление
db.products.updateOne(
  { _id: productId, "stock.ekb": { $gte: 1 } },
  { $inc: { "stock.ekb": -1 } }
)

// Пополнение остатка
db.products.updateOne({ _id: productId }, { $inc: { "stock.kgd": 30 } })

// Поиск по категории и диапазону цен — запрос на все шарды по индексу { category, price },
// чтение с реплик
db.products.find({ category: "electronics", price: { $gte: NumberDecimal("10000"), $lte: NumberDecimal("60000") } })
  .sort({ price: 1 }).limit(50).readPref("secondaryPreferred")
```

### 6.4. Операции с `carts`

```javascript
const now = new Date();
const ttl = new Date(now.getTime() + 7 * 24 * 3600 * 1000);   // корзина живёт 7 дней с последнего изменения

// Создание гостевой корзины (или получение существующей) — адресно
db.carts.updateOne(
  { owner_id: "s:9f8e7d6c", status: "active" },
  { $setOnInsert: { user_id: null, session_id: "9f8e7d6c", items: [], created_at: now },
    $set: { updated_at: now, expires_at: ttl } },
  { upsert: true }
)

// Получение текущей корзины гостя или пользователя — адресно
db.carts.findOne({ owner_id: "s:9f8e7d6c", status: "active" })
db.carts.findOne({ owner_id: "u:c-102938", status: "active" })

// Добавление товара или замена количества
// (сначала пробуем изменить количество, если товара нет — добавляем)
const r = db.carts.updateOne(
  { owner_id: "s:9f8e7d6c", status: "active", "items.product_id": productId },
  { $set: { "items.$.quantity": 3, updated_at: now, expires_at: ttl } }
)
if (r.matchedCount === 0) {
  db.carts.updateOne(
    { owner_id: "s:9f8e7d6c", status: "active" },
    { $push: { items: { product_id: productId, quantity: 3 } }, $set: { updated_at: now, expires_at: ttl } }
  )
}

// Удаление товара из корзины
db.carts.updateOne(
  { owner_id: "s:9f8e7d6c", status: "active" },
  { $pull: { items: { product_id: productId } }, $set: { updated_at: now, expires_at: ttl } }
)

// Отметка корзины как заказанной
db.carts.updateOne(
  { owner_id: "u:c-102938", status: "active" },
  { $set: { status: "ordered", updated_at: now } }
)
```

### 6.5. Слияние гостевой корзины в пользовательскую

Каждая операция адресная. Три шага выполняются в транзакции, чтобы гостевая корзина не была потеряна
или слита дважды.

```javascript
const session = db.getMongo().startSession();
const carts = session.getDatabase("shop").carts;
session.startTransaction({ writeConcern: { w: "majority" } });
try {
  const now = new Date();
  const ttl = new Date(now.getTime() + 7 * 24 * 3600 * 1000);

  // 1. Прочитать гостевую корзину
  const guest = carts.findOne({ owner_id: "s:9f8e7d6c", status: "active" });
  if (guest) {
    // 2. Добавить её товары в корзину пользователя (создать её, если нет)
    const user = carts.findOne({ owner_id: "u:c-102938", status: "active" })
      || { items: [], created_at: now };
    const merged = new Map(user.items.map(i => [i.product_id.toString(), i]));
    for (const i of guest.items) {
      const key = i.product_id.toString();
      if (merged.has(key)) merged.get(key).quantity += i.quantity;
      else merged.set(key, { product_id: i.product_id, quantity: i.quantity });
    }
    carts.updateOne(
      { owner_id: "u:c-102938", status: "active" },
      { $set: { items: [...merged.values()], user_id: "c-102938", session_id: null, updated_at: now, expires_at: ttl },
        $setOnInsert: { created_at: user.created_at } },
      { upsert: true }
    );
    // 3. Отметить гостевую корзину как abandoned
    carts.updateOne({ _id: guest._id, owner_id: guest.owner_id }, { $set: { status: "abandoned", updated_at: now } });
  }
  session.commitTransaction();
} catch (e) {
  session.abortTransaction();
  throw e;
} finally {
  session.endSession();
}
```

### 6.6. Проверка распределения

```javascript
use shop
db.orders.getShardDistribution()
db.products.getShardDistribution()
db.carts.getShardDistribution()

// Адресность запроса: в плане выполнения должен быть один шард (SINGLE_SHARD)
db.carts.find({ owner_id: "u:c-102938", status: "active" }).explain().queryPlanner.winningPlan.stage
db.orders.find({ customer_id: "c-102938" }).explain().queryPlanner.winningPlan.stage
// Поиск по категории — на все шарды (SHARD_MERGE)
db.products.find({ category: "electronics" }).explain().queryPlanner.winningPlan.stage
```

---

## 7. Итог

| Коллекция | Шард-ключ | Почему подходит |
|---|---|---|
| `orders` | `{ customer_id: "hashed" }` | высокая кардинальность, хеш убирает монотонность и горячий шард при пиковом создании заказов; история и статус заказа — адресные |
| `products` | `{ _id: "hashed" }` | самая частая запись (списание остатков) и карточка товара адресные; популярные товары распределены по всем шардам; поиск по категории обслуживается индексом на каждом шарде, кешем и чтением с реплик |
| `carts` | `{ owner_id: "hashed" }` | один ключ для гостей и пользователей: поиск по `session_id` и по `user_id` адресный, слияние — три адресные операции, нет перекоса из-за `user_id = null` у гостей |
