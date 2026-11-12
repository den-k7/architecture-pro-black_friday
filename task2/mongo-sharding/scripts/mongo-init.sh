#!/bin/bash
# Инициализация шардированного кластера MongoDB и наполнение тестовыми данными.
# Запускать из каталога mongo-sharding после `docker compose up -d`.
set -e

cd "$(dirname "$0")/.."

# Ждём, пока узел станет PRIMARY своего replica set
wait_primary() {
  local service=$1 port=$2
  echo "Ожидание PRIMARY на $service:$port..."
  for _ in $(seq 1 30); do
    if [ "$(docker compose exec -T "$service" mongosh --port "$port" --quiet --eval 'db.hello().isWritablePrimary')" = "true" ]; then
      return 0
    fi
    sleep 2
  done
  echo "$service:$port не стал PRIMARY" >&2
  exit 1
}

echo "1. Инициализация replica set конфиг-сервера"
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [{ _id: 0, host: "configSrv:27017" }]
})
EOF
wait_primary configSrv 27017

echo "2. Инициализация replica set шардов"
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate({ _id: "shard1", members: [{ _id: 0, host: "shard1:27018" }] })
EOF
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
rs.initiate({ _id: "shard2", members: [{ _id: 0, host: "shard2:27019" }] })
EOF
wait_primary shard1 27018
wait_primary shard2 27019

echo "3. Регистрация шардов в роутере, шардирование коллекции, наполнение данными"
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1:27018")
sh.addShard("shard2/shard2:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { name: "hashed" })
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({ age: i, name: "ly" + i })
print("Всего документов: " + db.helloDoc.countDocuments())
EOF

echo "4. Количество документов на шардах"
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
print("shard1: " + db.helloDoc.countDocuments())
EOF
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
use somedb
print("shard2: " + db.helloDoc.countDocuments())
EOF
