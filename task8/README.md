# Задание 8. Выявление и устранение «горячих» шардов

## 1. Проблема

На категорию «Электроника» приходится 70% запросов, и один шард MongoDB оказался перегружен.
Горячий шард — это шард, на который приходится непропорционально большая доля операций.
Он упирается в CPU, диск или кеш раньше остальных, и время ответа растёт для всех запросов кластера,
которые к нему обращаются. Остальные шарды при этом простаивают.

### 1.1. Причины

| Причина | Как проявляется |
|---|---|
| **Шард-ключ с низкой кардинальностью** — например, `{ category: 1 }` | Все товары категории имеют одно значение ключа и лежат в одном чанке. Такой чанк нельзя разделить (jumbo), а значит, нельзя и распределить. 70% запросов к «Электронике» идут на один шард. |
| **Монотонный шард-ключ** — `_id` типа ObjectId, дата | Все новые документы пишутся в последний чанк, то есть на один шард. |
| **Горячие документы** | Даже при хорошем ключе популярный товар (например, «Смартфон X» на распродаже) — один документ, и все списания его остатка идут на один шард. |
| **Балансировщик выравнивает объём, а не нагрузку** | Балансировщик MongoDB переносит чанки, пока разница *объёма данных* между шардами не станет меньше порога. Если на двух шардах одинаковый объём, но на одном лежит популярная категория, балансировщик считает кластер сбалансированным. |

Последний пункт — главный: **штатные механизмы MongoDB горячий шард по нагрузке не обнаруживают и не устраняют**.
Нужны собственные метрики и механизм перераспределения, описанные ниже.

### 1.2. Воспроизведение

Сценарий воспроизведён на кластере из задания 3 (MongoDB 9.0, два шарда по три реплики). Коллекция `shop.products`
содержит 20 000 товаров, из них 70% — «Электроника». Шард-ключ — `{ category: 1 }`, чанк «Электроники» лежит на `shard2`.
Нагрузка: 70% чтений и списаний остатков приходится на «Электронику».

| | shard1 | shard2 |
|---|---|---|
| Документов | 6 000 (30%) | 14 000 (70%) |
| Операций с коллекцией | 17,7% | **82,3%** |
| `sh.balancerCollectionStatus()` | `balancerCompliant: true` | |

Балансировщик считает коллекцию сбалансированной: разница в объёме данных меньше порога (три размера чанка).
При этом на `shard2` приходится больше 80% нагрузки.

---

## 2. Метрики мониторинга

Метрики собираются с каждого узла кластера (mongod каждого шарда, mongos, конфиг-сервер), например,
[percona/mongodb_exporter](https://github.com/percona/mongodb_exporter) в Prometheus. Каждой серии
в конфигурации сбора добавляются метки `shard` и `role` (`primary`/`secondary`), чтобы сравнивать шарды между собой.

Главный принцип: **сравнивать шарды друг с другом, а не с абсолютным порогом**. Горячий шард — это шард,
чья нагрузка заметно выше средней по кластеру. Для этого используется коэффициент дисбаланса:

```
imbalance(метрика) = значение метрики на шарде / среднее значение метрики по всем шардам
```

При равномерной нагрузке коэффициент близок к 1. Порог предупреждения — 1,5, критический — 2.

### 2.1. Нагрузка на шард

| Метрика | Источник | Зачем | Порог |
|---|---|---|---|
| Операций в секунду по шарду (insert, query, update, delete, getmore, command) | `db.serverStatus().opcounters` на PRIMARY каждого шарда | основной показатель дисбаланса нагрузки | imbalance > 1,5 в течение 10 мин |
| Операций по коллекции на каждом шарде (reads, writes) | `$collStats: { latencyStats: {} }` через mongos — по документу на шард | показывает, какая коллекция делает шард горячим | доля одного шарда > 1,5 / число шардов |
| Средняя задержка операций (reads, writes, commands) | `db.serverStatus().opLatencies` (`latency / ops`) | горячий шард отвечает медленнее остальных | p99 > 100 мс или imbalance > 2 |
| Медленные запросы | профилировщик (`setProfilingLevel(1, { slowms: 100 })`), лог `Slow query` | какие запросы и по каким значениям ключа нагружают шард | рост числа медленных запросов на одном шарде |
| Текущие операции и их длительность | `$currentOp` через mongos | долгие операции и блокировки в моменте | операции дольше 5 с |
| Счётчики блокировок по коллекциям | `db.adminCommand({ top: 1 })` на узле шарда | распределение чтений и записей по коллекциям внутри шарда | — |

### 2.2. Ресурсы узла

| Метрика | Источник | Зачем | Порог |
|---|---|---|---|
| CPU, load average | node_exporter / cAdvisor | горячий шард первым упирается в CPU | > 80% в течение 5 мин; imbalance > 1,5 |
| Дисковый ввод-вывод, задержка диска | node_exporter | чтение с диска при нехватке кеша | util > 80%, await > 20 мс |
| Кеш WiredTiger: заполнение и «грязные» данные | `serverStatus().wiredTiger.cache` | рабочий набор не помещается в память; запись не успевает сбрасываться | заполнение > 95%, dirty > 20% |
| Очереди и тикеты выполнения | `serverStatus().globalLock.currentQueue`, `serverStatus().queues.execution` | операции ждут выполнения — признак перегрузки | очередь > 0 дольше 1 мин; свободных тикетов 0 |
| Соединения | `serverStatus().connections.current` | рост соединений к одному шарду | imbalance > 1,5 |
| Отставание реплик | `rs.status()` (разница `optimeDate` PRIMARY и SECONDARY) | перегруженный PRIMARY не успевает отдавать oplog, чтение с реплик устаревает | > 10 с |

### 2.3. Распределение данных

| Метрика | Источник | Зачем | Порог |
|---|---|---|---|
| Документов и байт на каждом шарде (без orphan-документов) | `$shardedDataDistribution` | перекос по объёму данных | imbalance > 1,3 |
| Чанков коллекции на каждом шарде | `config.chunks` | неравномерное число чанков | — |
| Jumbo-чанки | `config.chunks.find({ jumbo: true })` | неделимые чанки, которые балансировщик не может перенести | > 0 |
| Чанков на шарде в зоне | `config.tags`, `config.chunks` | соответствие зонам | — |

### 2.4. Качество шард-ключа

| Метрика | Источник | Зачем |
|---|---|---|
| Кардинальность, самые частые значения, монотонность ключа | `analyzeShardKey` с `keyCharacteristics: true` | у ключа `{ category: 1 }` 4 различных значения, на «Электронику» приходится 14 000 из 20 000 документов |
| Доля адресных (single-shard) и широковещательных (scatter-gather) запросов, распределение чтений и записей по диапазонам ключа | `configureQueryAnalyzer` + `analyzeShardKey` с `readWriteDistribution: true` | показывает, на какие диапазоны ключа приходятся запросы, и позволяет оценить ключ-кандидат до решардинга |

### 2.5. Балансировщик и миграции

| Метрика | Источник | Зачем | Порог |
|---|---|---|---|
| Балансировщик включён и работает | `sh.getBalancerState()`, `db.adminCommand({ balancerStatus: 1 })` | выключенный балансировщик — частая причина перекоса | `mode != "full"` |
| Соответствие коллекции балансировке | `sh.balancerCollectionStatus(ns)` | `balancerCompliant: false` и причина | false дольше 1 ч |
| Миграции чанков: число, длительность, ошибки | `config.changelog` (`moveChunk.*`), лог `MIGRATE` | миграции сами нагружают шарды; частые неудачи — признак проблемы | ошибки миграций > 0 |
| Задачи удаления orphan-документов | `config.rangeDeletions` на узлах шардов | пока они не выполнены, новые миграции этого диапазона ждут | > 0 дольше 1 ч |

### 2.6. Правила оповещений Prometheus

Пример правил для метрик percona/mongodb_exporter (метка `shard` задаётся в конфигурации сбора;
имена метрик зависят от версии экспортёра).

```yaml
groups:
  - name: mongodb-hot-shard
    rules:
      # Операций в секунду на PRIMARY каждого шарда
      - record: shard:ops:rate5m
        expr: sum by (shard) (rate(mongodb_ss_opcounters{role="primary", legacy_op_type!="command"}[5m]))

      # Коэффициент дисбаланса нагрузки
      - record: shard:ops:imbalance
        expr: shard:ops:rate5m / scalar(avg(shard:ops:rate5m))

      - alert: MongoHotShard
        expr: shard:ops:imbalance > 1.5
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "Горячий шард {{ $labels.shard }}: нагрузка в {{ $value | printf \"%.1f\" }} раза выше средней"
          runbook: "task8/README.md, раздел 4"

      - alert: MongoHotShardCritical
        expr: shard:ops:imbalance > 2
        for: 5m
        labels: { severity: critical }

      # Средняя задержка чтения на шарде, мкс
      - alert: MongoShardHighLatency
        expr: |
          sum by (shard) (rate(mongodb_ss_opLatencies_latency{op_type="reads", role="primary"}[5m]))
          / sum by (shard) (rate(mongodb_ss_opLatencies_ops{op_type="reads", role="primary"}[5m])) > 100000
        for: 5m
        labels: { severity: warning }

      # Операции ждут в очереди
      - alert: MongoShardQueue
        expr: sum by (shard) (mongodb_ss_globalLock_currentQueue{count_type!="total"}) > 10
        for: 2m
        labels: { severity: warning }

      # Кеш WiredTiger заполнен
      - alert: MongoShardCacheFull
        expr: |
          mongodb_ss_wt_cache_bytes_currently_in_the_cache
          / mongodb_ss_wt_cache_maximum_bytes_configured > 0.95
        for: 10m
        labels: { severity: warning }
```

На дашборде Grafana для каждого шарда рядом выводятся: операции в секунду и коэффициент дисбаланса,
задержки, CPU, кеш WiredTiger, очереди, документы на шарде и число миграций.

---

## 3. Выявление горячего шарда: команды

Все команды, кроме отмеченных, выполняются через роутер:

```shell
docker compose exec -T mongos_router mongosh --port 27020
```

### 3.1. Нагрузка по шардам для коллекции

`$collStats` через mongos возвращает отдельный документ для каждого шарда. Счётчики накопительные,
поэтому нагрузку за период считают как разницу двух замеров.

```javascript
use shop
db.products.aggregate([
  { $collStats: { latencyStats: {} } },
  { $project: { _id: 0, shard: 1,
      reads: "$latencyStats.reads.ops", writes: "$latencyStats.writes.ops",
      readLatencyMicros: "$latencyStats.reads.latency" } }
])
```

### 3.2. Распределение данных

```javascript
// Документы и байты на шардах без учёта orphan-документов
db.getSiblingDB("admin").aggregate([
  { $shardedDataDistribution: {} },
  { $match: { ns: "shop.products" } }
])

// Чанки коллекции по шардам
const uuid = db.getSiblingDB("config").collections.findOne({ _id: "shop.products" }).uuid
db.getSiblingDB("config").chunks.aggregate([
  { $match: { uuid: uuid } },
  { $group: { _id: "$shard", chunks: { $sum: 1 }, jumbo: { $sum: { $cond: ["$jumbo", 1, 0] } } } }
])

db.products.getShardDistribution()
sh.balancerCollectionStatus("shop.products")
```

### 3.3. Метрики узла шарда

Выполняются на PRIMARY шарда, например `docker compose exec -T shard2-1 mongosh --port 27019`:

```javascript
const s = db.serverStatus()
s.opcounters                                   // операции по типам
s.opLatencies                                  // суммарная задержка и число операций: reads, writes, commands
s.globalLock.currentQueue                      // операции в очереди
s.queues.execution                             // тикеты выполнения: занятые и свободные
s.wiredTiger.cache["bytes currently in the cache"]
s.wiredTiger.cache["tracked dirty bytes in the cache"]
s.connections

db.adminCommand({ top: 1 }).totals["shop.products"]   // чтения и записи коллекции на этом шарде

// Профилировщик: запросы дольше 100 мс попадают в system.profile
db.getSiblingDB("shop").setProfilingLevel(1, { slowms: 100 })
db.getSiblingDB("shop").system.profile.aggregate([
  { $group: { _id: { op: "$op", filter: "$command.filter.category" }, n: { $sum: 1 }, avgMs: { $avg: "$millis" } } },
  { $sort: { n: -1 } }, { $limit: 10 }
])
```

### 3.4. Анализ шард-ключа

```javascript
// Характеристики текущего ключа: кардинальность, частые значения, монотонность
db.adminCommand({ analyzeShardKey: "shop.products", key: { category: 1 }, keyCharacteristics: true, readWriteDistribution: false })
// Результат на воспроизведённом сценарии:
//   numDistinctValues: 4
//   mostCommonValues: electronics — 14000, audio — 4000, home — 4000, toys — 4000
//   monotonicity: "not monotonic"

// Включить выборку запросов (не больше 50 запросов в секунду)
db.adminCommand({ configureQueryAnalyzer: "shop.products", mode: "full", samplesPerSecond: 50 })

// ...после накопления выборки оценить ключ-кандидат по реальным запросам
db.products.createIndex({ category: 1, _id: 1 })
db.adminCommand({ analyzeShardKey: "shop.products", key: { category: 1, _id: 1 }, keyCharacteristics: true, readWriteDistribution: true })
// readDistribution.numReadsByRange и writeDistribution.numWritesByRange показывают,
// на какие диапазоны ключа приходятся запросы; percentageOfSingleShardReads — долю адресных чтений

db.adminCommand({ configureQueryAnalyzer: "shop.products", mode: "off" })
```

Для ключа с низкой кардинальностью `analyzeShardKey` с `readWriteDistribution: true` завершается ошибкой
«The shard key provided does not have enough cardinality…». Это само по себе сигнал, что ключ не подходит.

---

## 4. Устранение дисбаланса

Меры расположены от быстрых, которые снимают нагрузку сразу, к структурным, которые убирают причину.

### 4.1. Быстрые меры: снять нагрузку чтения

Большинство запросов к «Электронике» — чтение каталога и карточек товаров.

- **Чтение с реплик.** Каждый шард — replica set из трёх узлов. Чтение каталога направляется на SECONDARY,
  а PRIMARY остаётся для записи (списание остатков):

  ```
  mongodb://mongos_router:27020/shop?readPreference=secondaryPreferred&maxStalenessSeconds=90
  ```

  или для отдельного запроса:

  ```javascript
  db.products.find({ category: "electronics", price: { $lte: NumberDecimal("50000") } }).readPref("secondaryPreferred")
  ```

  Чтобы нагрузка на чтение не упиралась в одну реплику, в горячий шард можно добавить SECONDARY:
  `rs.add("shard2-4:27019")` на PRIMARY шарда.
- **Кеш приложения.** Каталог и карточки популярных товаров кешируются в Redis (схема 3).
  Для горячих категорий TTL увеличивается, а кеш прогревается перед распродажей.
- **CDN.** Изображения и статика страниц отдаются из CDN (схема 5) и до MongoDB не доходят.

### 4.2. Разделить горячий чанк и перенести его часть

Если шард-ключ позволяет делить чанк горячей категории, чанк делится, а половина переносится на менее
нагруженный шард. Это делает скрипт из раздела 5 автоматически; вручную:

```javascript
// Разделить чанк по медиане
sh.splitFind("shop.products", { category: "electronics", _id: ObjectId("6af5ab0652cb0a797266fb52") })
// или в заданной точке
sh.splitAt("shop.products", { category: "electronics", _id: ObjectId("6af5ab0652cb0a797266fb52") })

// Перенести диапазон на менее нагруженный шард
db.adminCommand({
  moveRange: "shop.products",
  min: { category: "electronics", _id: ObjectId("6af5ab0652cb0a797266fb52") },
  max: { category: "home", _id: MinKey },
  toShard: "shard1"
})
```

При ключе `{ category: 1 }` разделить чанк одной категории нельзя:
«Unable to find median in chunk because chunk is indivisible». Сначала нужно изменить ключ (4.3).

После переноса на исходном шарде остаются orphan-документы — копии перенесённого диапазона. Они удаляются
через `orphanCleanupDelaySecs` (в MongoDB 9.0 по умолчанию 3600 с). Пока они не удалены, новый перенос
пересекающегося диапазона с этого шарда ждёт. Поэтому за один раз переносят ограниченный объём,
а очередь удалений контролируют метрикой `config.rangeDeletions` (2.5).

### 4.3. Изменить шард-ключ

**Уточнить ключ** (`refineCollectionShardKey`, MongoDB 4.4+). Добавляет к существующему ключу поля-суффиксы,
не перемещая данные. Операция быстрая, но с ключом `{ category: 1, _id: 1 }` новые товары внутри категории
по-прежнему пишутся в последний чанк категории (ObjectId монотонен).

```javascript
db.products.createIndex({ category: 1, _id: 1 })
db.adminCommand({ refineCollectionShardKey: "shop.products", key: { category: 1, _id: 1 } })
```

**Решардинг** (`reshardCollection`, MongoDB 5.0+). Полностью меняет ключ и перераспределяет данные онлайн:
приложение продолжает читать и писать, запись блокируется только на последние ~2 секунды.
Рекомендуемый ключ для `products` — `{ category: 1, _id: "hashed" }`: запросы по категории остаются адресными
(уходят только на шарды с чанками этой категории), а внутри категории товары распределены по хешу `_id`
между всеми шардами, без монотонности.

```javascript
sh.reshardCollection("shop.products", { category: 1, _id: "hashed" })

// Ход решардинга
db.getSiblingDB("admin").aggregate([
  { $currentOp: { allUsers: true, localOps: false } },
  { $match: { type: "op", "originatingCommand.reshardCollection": "shop.products" } }
])
```

На воспроизведённом сценарии решардинг 20 000 документов занял 37 секунд. После него чанки «Электроники»
чередуются между `shard1` и `shard2`. Решардинг требует свободного места на шардах примерно в объёме коллекции
и сам создаёт нагрузку, поэтому его запускают вне пика.

Если по категориям не нужно делать адресные запросы, подходит ключ `{ _id: "hashed" }` (выбран в задании 7):
он распределяет товары равномерно независимо от категории.

### 4.4. Зонное шардирование: больше шардов для популярной категории

Зоны задают, на каких шардах может лежать диапазон ключа. Для популярной категории выделяется зона
из нескольких шардов (в том числе новых, более мощных), и балансировщик распределяет её чанки внутри зоны.
Требует ключа, по которому категорию можно разделить на чанки, — например, `{ category: 1, _id: "hashed" }`.

```javascript
// Зона «Электроники» — шарды shard2 и shard3
sh.addShardToZone("shard2", "electronics")
sh.addShardToZone("shard3", "electronics")
sh.updateZoneKeyRange(
  "shop.products",
  { category: "electronics", _id: MinKey },
  { category: "electronics", _id: MaxKey },
  "electronics"
)

// Остальные категории — на остальных шардах
sh.addShardToZone("shard1", "regular")
sh.updateZoneKeyRange("shop.products", { category: MinKey, _id: MinKey }, { category: "electronics", _id: MinKey }, "regular")
sh.updateZoneKeyRange("shop.products", { category: "electronics", _id: MaxKey }, { category: MaxKey, _id: MaxKey }, "regular")

// Проверка
db.getSiblingDB("config").tags.find({ ns: "shop.products" })
sh.balancerCollectionStatus("shop.products")   // balancerCompliant: true, когда чанки разложены по зонам
```

Зоны также позволяют держать данные региона на шардах в этом регионе (например, заказы по `geo_zone`).

### 4.5. Добавить шард

Если нагрузка выросла на весь кластер, добавляется новый шард (replica set из трёх узлов).
Балансировщик сам переносит на него чанки.

```javascript
sh.addShard("shard3/shard3-1:27021,shard3-2:27021,shard3-3:27021")
```

### 4.6. Горячие документы: остатки популярных товаров

Даже при идеальном ключе остаток «Смартфона X» хранится в одном документе, и все его списания идут на один шард.
Для популярных товаров остатки выносятся в отдельную коллекцию по паре «товар — геозона».
Тогда списания одного товара в разных регионах распределяются по разным шардам:

```javascript
sh.shardCollection("shop.stocks", { _id: "hashed" })

// _id: "<product_id>:<geo_zone>"
db.stocks.insertMany([
  { _id: "6750a1f2c3d4e5f6a7b8c9d1:msk", product_id: ObjectId("6750a1f2c3d4e5f6a7b8c9d1"), geo_zone: "msk", qty: 120 },
  { _id: "6750a1f2c3d4e5f6a7b8c9d1:ekb", product_id: ObjectId("6750a1f2c3d4e5f6a7b8c9d1"), geo_zone: "ekb", qty: 50 }
])

// Списание — адресное условное обновление одного документа
db.stocks.updateOne({ _id: "6750a1f2c3d4e5f6a7b8c9d1:msk", qty: { $gte: 1 } }, { $inc: { qty: -1 } })
```

### 4.7. Настройки балансировщика

```javascript
// Балансировщик включён
sh.getBalancerState()
sh.startBalancer()

// Меньший размер чанка для горячей коллекции — балансировщик раскладывает её более мелкими частями
db.adminCommand({ configureCollectionBalancing: "shop.products", chunkSize: 32 })   // МБ

// Размер чанка по умолчанию для кластера (МБ, по умолчанию 128)
db.getSiblingDB("config").settings.updateOne({ _id: "chunksize" }, { $set: { value: 64 } }, { upsert: true })

// Окно работы балансировщика: миграции ночью, вне пика нагрузки
db.getSiblingDB("config").settings.updateOne(
  { _id: "balancer" },
  { $set: { activeWindow: { start: "01:00", stop: "06:00" } } },
  { upsert: true }
)
```

Во время распродажи окно балансировщика лучше не ограничивать: если горячий шард появился днём,
ждать до ночи нельзя. Ограничение нужно, только если миграции сами мешают пиковой нагрузке.

---

## 5. Автоматическое перераспределение

Балансировщик MongoDB выравнивает объём данных, поэтому он дополняется собственным контуром,
который выравнивает **нагрузку**:

```
метрики (exporter → Prometheus) ──► алерт MongoHotShard ──► hot-shard-check.js ──► split + moveRange
        ▲                                                         │
        └───────────────── замер после переноса ◄─────────────────┘
```

### 5.1. Скрипт `hot-shard-check.js`

Скрипт [scripts/hot-shard-check.js](scripts/hot-shard-check.js) запускается через mongos:

1. Дважды снимает `$collStats` (`latencyStats`) всех шардированных коллекций с интервалом `HOT_INTERVAL_SEC`
   и считает число операций каждого шарда за интервал.
2. Считает коэффициент дисбаланса: нагрузка шарда / средняя нагрузка. Если он ниже `HOT_THRESHOLD`
   или операций меньше `HOT_MIN_OPS`, завершается с кодом 0.
3. Находит горячий шард, коллекцию, которая даёт на нём основную нагрузку, и наименее нагруженный шард.
4. В режиме `HOT_AUTO_MOVE=true` делит чанк этой коллекции на горячем шарде пополам (`split` с `bounds`)
   и переносит верхнюю половину на наименее нагруженный шард (`moveRange`). За один запуск переносится
   не больше `HOT_MAX_MOVES` диапазонов, чтобы миграции не добавили нагрузки и так горячему шарду.
5. Если чанк разделить нельзя (ключ с низкой кардинальностью), рекомендует `refineCollectionShardKey`
   или `reshardCollection`.

Коды выхода: 0 — дисбаланса нет; 2 — дисбаланс найден, перенос не выполнен; 3 — выполнен перенос.

Запуск на кластере из задания 3 (команды выполняются из каталога `task8`; в Git Bash на Windows
перед ними нужно `export MSYS_NO_PATHCONV=1`):

```shell
docker cp scripts/hot-shard-check.js mongos_router:/tmp/hot-shard-check.js

# Отчёт
docker exec -e HOT_INTERVAL_SEC=60 mongos_router mongosh --port 27020 --quiet --file /tmp/hot-shard-check.js

# Отчёт и автоматический перенос
docker exec -e HOT_INTERVAL_SEC=60 -e HOT_AUTO_MOVE=true mongos_router mongosh --port 27020 --quiet --file /tmp/hot-shard-check.js
```

Скрипт запускается по расписанию (cron, Kubernetes CronJob) каждые 5–10 минут или по алерту
`MongoHotShard` через Alertmanager webhook. Каждый запуск переносит не больше одного диапазона,
а следующий запуск проверяет результат. Так нагрузка выравнивается постепенно и без лишних миграций.

### 5.2. Проверка на воспроизведённом сценарии

Нагрузка: два параллельных клиента, 70% операций — чтение и списание остатков «Электроники».

**Ключ `{ category: 1 }`** — горячий шард найден, но чанк разделить нельзя:

```
shard1: 508 ops, 17.7%, ratio 0.35
shard2: 2366 ops, 82.3%, ratio 1.65
HOT: shard2 (ratio 1.65), самая нагруженная коллекция shop.products: 2364 ops, чанков на шарде: 1
  нельзя разделить {"category":"electronics"}: Unable to find median in chunk because chunk is indivisible.
  рекомендация: refineCollectionShardKey или reshardCollection для shop.products
```

**После `refineCollectionShardKey` до `{ category: 1, _id: 1 }`** — первый запуск разделил чанк «Электроники»
и перенёс половину на `shard1`, второй запуск подтвердил, что дисбаланс устранён:

```
--- запуск 1
Всего операций: 2670
  shard1: 472 ops, 17.7%, ratio 0.35
  shard2: 2198 ops, 82.3%, ratio 1.65
  moveRange shop.products {"category":"electronics","_id":{"$oid":"6af5ab0652cb0a797266fb52"}} .. {"category":"home","_id":{"$minKey":1}}: shard2 -> shard1
  результат: ok
--- запуск 2
Всего операций: 6314
  shard1: 3434 ops, 54.4%, ratio 1.09
  shard2: 2880 ops, 45.6%, ratio 0.91
OK: дисбаланс 1.09 < 1.5
```

Нагрузка выровнялась с 82% / 18% до 54% / 46%. Те же клиенты за 15 секунд выполнили в 2,4 раза больше
операций (6314 против 2670): шарды перестали ждать друг друга.

---

## 6. Порядок действий при горячем шарде

1. **Обнаружить.** Алерт `MongoHotShard` (дисбаланс > 1,5 дольше 10 минут) или рост задержек на одном шарде.
2. **Найти причину.** `$collStats` — какая коллекция; профилировщик и `analyzeShardKey` — какие значения
   ключа и запросы; `config.chunks` — есть ли jumbo-чанки.
3. **Снять нагрузку чтения.** `secondaryPreferred` для каталога, увеличение TTL кеша, при необходимости —
   дополнительная реплика в горячем шарде.
4. **Перераспределить данные.** Если ключ позволяет — `hot-shard-check.js` с `HOT_AUTO_MOVE=true`
   (split + moveRange). Если нет — `refineCollectionShardKey` сразу и `reshardCollection` вне пика.
5. **Закрепить.** Для постоянно популярных категорий — зона из нескольких шардов; для горячих товаров —
   остатки в отдельной коллекции `stocks`; при общем росте — новый шард.
6. **Проверить.** Коэффициент дисбаланса < 1,5, задержки вернулись к норме, `balancerCompliant: true`.

## 7. Итог

| Задача | Решение |
|---|---|
| Выявлять горячие шарды | метрики нагрузки по шардам с коэффициентом дисбаланса (opcounters, `$collStats`, задержки, очереди, кеш), распределения данных (`$shardedDataDistribution`, jumbo-чанки) и качества ключа (`analyzeShardKey`); алерты Prometheus |
| Автоматически перераспределять | штатный балансировщик для объёма данных + `hot-shard-check.js` для нагрузки: split + moveRange по алерту или расписанию |
| Устранять причину | ключ с высокой кардинальностью без монотонности (`{ category: 1, _id: "hashed" }` через `reshardCollection`), зоны для популярных категорий, отдельная коллекция остатков для горячих товаров |
| Снижать нагрузку | чтение с реплик, кеш Redis, CDN, добавление шардов |
