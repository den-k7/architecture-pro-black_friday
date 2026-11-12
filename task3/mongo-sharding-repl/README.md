# mongo-sharding-repl

Шардированный кластер MongoDB с репликацией (схема 2 из задания 1) и приложение `pymongo-api`.
Конфиг-сервер и каждый из двух шардов — replica set из трёх узлов.

| Сервис | Роль | Replica set | Порт |
|---|---|---|---|
| `configSrv1`, `configSrv2`, `configSrv3` | конфиг-сервер | `config_server` | 27017 |
| `shard1-1`, `shard1-2`, `shard1-3` | шард 1 | `shard1` | 27018 |
| `shard2-1`, `shard2-2`, `shard2-3` | шард 2 | `shard2` | 27019 |
| `mongos_router` | роутер запросов, к нему подключается приложение | — | 27020 |
| `pymongo_api` | приложение | — | 8080 |

База — `somedb`, коллекция — `helloDoc`, ключ шардирования — `{ name: "hashed" }`.

Проект самостоятельный и не зависит от `task2/mongo-sharding`. Оба проекта публикуют порт 8080
и используют контейнеры `mongos_router` и `pymongo_api`, поэтому одновременно можно запускать
только один из них. Перед запуском остановите другой проект (`docker compose down` в его каталоге).

## Как запустить

Все команды выполняются из каталога `mongo-sharding-repl`.

1. Запустить кластер и приложение:

```shell
docker compose up -d
```

Проверить, что контейнеры запущены:

```shell
docker compose ps
```

Все узлы `configSrv*`, `shard1-*`, `shard2-*` должны быть `healthy`. `mongos_router` остаётся `unhealthy`,
пока не инициализирован replica set конфиг-сервера (следующий шаг), — это нормально.

2. Настроить репликацию и шардирование, заполнить базу данными:

```shell
./scripts/mongo-init.sh
```

Скрипт выполняет шаги, описанные ниже. В конце он печатает общее количество документов, а также
количество документов и реплик на каждом шарде. Скрипт запускается один раз; чтобы начать заново, выполните `docker compose down -v`.

> Если образ с зеркала `dh-mirror.gitverse.ru` недоступен, можно взять образ с Docker Hub:
> `MONGO_IMAGE=mongo:7.0 docker compose up -d`

## Как настроить репликацию (что делает скрипт)

Каждый узел mongod запускается с параметром `--replSet <имя>`: узлы конфиг-сервера — с `--configsvr --replSet config_server`,
узлы шардов — с `--shardsvr --replSet shard1` или `--shardsvr --replSet shard2` (см. `compose.yaml`).
Узлы одного replica set объединяются командой `rs.initiate`, которую достаточно выполнить на одном из них.

1. Создать replica set конфиг-сервера из трёх узлов:

```shell
docker compose exec -T configSrv1 mongosh --port 27017 --quiet <<EOF
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv1:27017", priority: 2 },
    { _id: 1, host: "configSrv2:27017" },
    { _id: 2, host: "configSrv3:27017" }
  ]
})
EOF
```

2. Создать replica set каждого шарда из трёх узлов:

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard1",
  members: [
    { _id: 0, host: "shard1-1:27018", priority: 2 },
    { _id: 1, host: "shard1-2:27018" },
    { _id: 2, host: "shard1-3:27018" }
  ]
})
EOF

docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
rs.initiate({
  _id: "shard2",
  members: [
    { _id: 0, host: "shard2-1:27019", priority: 2 },
    { _id: 1, host: "shard2-2:27019" },
    { _id: 2, host: "shard2-3:27019" }
  ]
})
EOF
```

3. Дождаться, пока в каждом replica set будет выбран PRIMARY. Первому узлу задан `priority: 2`, поэтому PRIMARY — `configSrv1`, `shard1-1`, `shard2-1`, остальные узлы — SECONDARY.
Состояние можно посмотреть так:

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval 'rs.status().members.map(m => m.name + " " + m.stateStr)'
```

4. Через роутер зарегистрировать шарды, указав все узлы их replica set, включить шардирование и заполнить коллекцию:

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { name: "hashed" })
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({ age: i, name: "ly" + i })
EOF
```

Роутер подключается ко всем узлам конфиг-сервера: `--configdb config_server/configSrv1:27017,configSrv2:27017,configSrv3:27017`.

## Как проверить

### Через приложение

Откройте http://localhost:8080 (или `http://<ip виртуальной машины>:8080`). В ответе:

- `mongo_topology_type: "Sharded"`;
- `collections.helloDoc.documents_count` — общее количество документов (1000);
- `collections.helloDoc.shards` — количество документов на каждом шарде;
- `shards.<шард>.replicas_count` — количество реплик шарда (3), `shards.<шард>.replicas` — адреса реплик.

Swagger: http://localhost:8080/docs

### Через mongosh

Общее количество документов через роутер:

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'
```

Распределение данных по шардам:

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.getShardDistribution()'
```

Состав replica set шарда (аналогично для `shard2-1:27019` и `configSrv1:27017`):

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval 'rs.status().members.map(m => m.name + " " + m.stateStr)'
```

Количество документов на реплике (данные одинаковы на всех узлах replica set):

```shell
docker compose exec -T shard1-2 mongosh --port 27018 --quiet --eval 'db.getMongo().setReadPref("secondaryPreferred"); db.getSiblingDB("somedb").helloDoc.countDocuments()'
```

## Как остановить

```shell
docker compose down      # сохранить данные
docker compose down -v   # удалить и данные
```
