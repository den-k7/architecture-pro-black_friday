# mongo-sharding

Шардированный кластер MongoDB (схема 1 из задания 1) и приложение `pymongo-api`.

| Сервис | Роль | Порт |
|---|---|---|
| `configSrv` | конфиг-сервер, replica set `config_server` | 27017 |
| `shard1` | шард 1, replica set `shard1` | 27018 |
| `shard2` | шард 2, replica set `shard2` | 27019 |
| `mongos_router` | роутер запросов, к нему подключается приложение | 27020 |
| `pymongo_api` | приложение, образ `kazhem/pymongo_api:1.0.0` | 8080 |

База — `somedb`, коллекция — `helloDoc`, ключ шардирования — `{ name: "hashed" }`.

## Как запустить

Все команды выполняются из каталога `mongo-sharding`.

1. Запустить кластер и приложение:

```shell
docker compose up -d
```

Проверить, что контейнеры запущены:

```shell
docker compose ps
```

`configSrv`, `shard1`, `shard2` должны быть `healthy`. `mongos_router` остаётся `unhealthy`, пока не инициализирован
replica set конфиг-сервера (следующий шаг), — это нормально.

2. Инициализировать шардирование и заполнить базу данными:

```shell
./scripts/mongo-init.sh
```

Скрипт выполняет шаги, описанные ниже, и в конце печатает общее количество документов и количество на каждом шарде.

> Если образ с зеркала `dh-mirror.gitverse.ru` недоступен, можно взять образ с Docker Hub:
> `MONGO_IMAGE=mongo:7.0 docker compose up -d`

## Что делает скрипт инициализации

1. Инициализирует replica set конфиг-сервера:

```shell
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [{ _id: 0, host: "configSrv:27017" }]
})
EOF
```

2. Инициализирует replica set каждого шарда:

```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate({ _id: "shard1", members: [{ _id: 0, host: "shard1:27018" }] })
EOF

docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
rs.initiate({ _id: "shard2", members: [{ _id: 0, host: "shard2:27019" }] })
EOF
```

3. Дожидается, пока каждый узел станет PRIMARY (`db.hello().isWritablePrimary`).

4. Через роутер регистрирует шарды, включает шардирование базы и коллекции, заполняет коллекцию:

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1:27018")
sh.addShard("shard2/shard2:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { name: "hashed" })
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({ age: i, name: "ly" + i })
EOF
```

## Как проверить

### Через приложение

Откройте http://localhost:8080 (или `http://<ip виртуальной машины>:8080`). В ответе:

- `mongo_topology_type: "Sharded"`;
- `collections.helloDoc.documents_count` — общее количество документов (1000);
- `shards` — список шардов и их адреса.

Количество документов на каждом шарде приложение не выводит: его печатает `scripts/mongo-init.sh`,
а также показывают команды из раздела «Через mongosh».

Swagger: http://localhost:8080/docs

### Через mongosh

Общее количество через роутер:

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Количество на каждом шарде:

```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Распределение данных по шардам:

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.getShardDistribution()
EOF
```

## Как остановить

```shell
docker compose down      # сохранить данные
docker compose down -v   # удалить и данные
```
