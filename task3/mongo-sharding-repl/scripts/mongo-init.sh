#!/bin/bash
# Настройка репликации и шардирования MongoDB, наполнение тестовыми данными.
# Запускать один раз после `docker compose up -d`.
set -e

cd "$(dirname "$0")/.."

# Ждём, пока узел станет PRIMARY своего replica set
wait_primary() {
  echo "Ожидание PRIMARY на $1..."
  until [ "$(docker compose exec -T "$1" mongosh --port "$2" --quiet --eval 'db.hello().isWritablePrimary')" = "true" ]; do
    sleep 2
  done
}

echo "1. Replica set конфиг-сервера"
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

echo "2. Replica set шардов"
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

wait_primary configSrv1 27017
wait_primary shard1-1 27018
wait_primary shard2-1 27019

echo "3. Шардирование и наполнение данными"
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { name: "hashed" })
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({ age: i, name: "ly" + i })
print("Всего документов: " + db.helloDoc.countDocuments())
EOF

echo "4. Документы и реплики на шардах"
docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval \
  'print("shard1: документов " + db.getSiblingDB("somedb").helloDoc.countDocuments() + ", реплик " + rs.status().members.length)'
docker compose exec -T shard2-1 mongosh --port 27019 --quiet --eval \
  'print("shard2: документов " + db.getSiblingDB("somedb").helloDoc.countDocuments() + ", реплик " + rs.status().members.length)'
