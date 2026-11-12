// Выявление «горячих» шардов и их автоматическая разгрузка.
//
// Запуск (через роутер):
//   mongosh "mongodb://mongos_router:27020" --quiet --file hot-shard-check.js
// Параметры передаются переменными окружения:
//   HOT_INTERVAL_SEC  — длительность замера нагрузки, с (по умолчанию 60)
//   HOT_THRESHOLD     — порог дисбаланса: нагрузка шарда / средняя нагрузка (по умолчанию 1.5)
//   HOT_MIN_OPS       — минимальное число операций за замер, ниже которого дисбаланс не считается (по умолчанию 1000)
//   HOT_AUTO_MOVE     — "true": делить и переносить чанки горячей коллекции (по умолчанию только отчёт)
//   HOT_MAX_MOVES     — максимум переносов за один запуск (по умолчанию 1)
//
// Почему не хватает штатного балансировщика: он выравнивает ОБЪЁМ данных между шардами,
// а не нагрузку. Шард с той же долей данных, но с самой популярной категорией, балансировщик горячим не считает.

const env = (name, def) => (typeof process !== "undefined" && process.env[name]) || def;
const CFG = {
  intervalSec: Number(env("HOT_INTERVAL_SEC", 60)),
  threshold: Number(env("HOT_THRESHOLD", 1.5)),
  minOps: Number(env("HOT_MIN_OPS", 1000)),
  autoMove: env("HOT_AUTO_MOVE", "false") === "true",
  maxMoves: Number(env("HOT_MAX_MOVES", 1)),
};

const config = db.getSiblingDB("config");
const shards = db.adminCommand({ listShards: 1 }).shards.map(s => s._id);

// Счётчики операций (reads + writes) по каждому шарду для каждой шардированной коллекции.
// $collStats через mongos возвращает отдельный документ на каждый шард, где лежит коллекция.
function snapshot() {
  const res = {};
  config.collections.find({ _id: { $not: /^config\./ }, key: { $exists: true } }).forEach(coll => {
    const [dbName, ...rest] = coll._id.split(".");
    const collName = rest.join(".");
    try {
      db.getSiblingDB(dbName).getCollection(collName)
        .aggregate([{ $collStats: { latencyStats: {} } }])
        .forEach(s => {
          res[coll._id] = res[coll._id] || {};
          res[coll._id][s.shard] = {
            reads: Number(s.latencyStats.reads.ops),
            writes: Number(s.latencyStats.writes.ops),
          };
        });
    } catch (e) {
      print(`WARN ${coll._id}: ${e.message}`);
    }
  });
  return res;
}

function chunksOf(ns) {
  const coll = config.collections.findOne({ _id: ns });
  return config.chunks.find({ uuid: coll.uuid }).sort({ min: 1 }).toArray();
}

print(`Замер нагрузки ${CFG.intervalSec} с, порог дисбаланса ${CFG.threshold}, шарды: ${shards.join(", ")}`);
const before = snapshot();
sleep(CFG.intervalSec * 1000);
const after = snapshot();

// Дельта операций за интервал
const perShard = Object.fromEntries(shards.map(s => [s, 0]));
const perColl = {};
for (const ns in after) {
  for (const shard in after[ns]) {
    const b = (before[ns] && before[ns][shard]) || { reads: 0, writes: 0 };
    const ops = after[ns][shard].reads - b.reads + after[ns][shard].writes - b.writes;
    perShard[shard] = (perShard[shard] || 0) + ops;
    perColl[ns] = perColl[ns] || {};
    perColl[ns][shard] = ops;
  }
}

const total = Object.values(perShard).reduce((a, b) => a + b, 0);
const avg = total / shards.length;
print(`Всего операций: ${total}`);
for (const s of shards) {
  const ratio = avg ? perShard[s] / avg : 0;
  print(`  ${s}: ${perShard[s]} ops, ${(100 * perShard[s] / (total || 1)).toFixed(1)}%, ratio ${ratio.toFixed(2)}`);
}

if (total < CFG.minOps) {
  print(`Нагрузка ниже ${CFG.minOps} операций — дисбаланс не оценивается`);
  quit(0);
}

const hot = shards.reduce((a, b) => (perShard[a] >= perShard[b] ? a : b));
const cold = shards.reduce((a, b) => (perShard[a] <= perShard[b] ? a : b));
const ratio = perShard[hot] / avg;
if (ratio < CFG.threshold) {
  print(`OK: дисбаланс ${ratio.toFixed(2)} < ${CFG.threshold}`);
  quit(0);
}

// Коллекция, дающая основную нагрузку на горячий шард
const hotNs = Object.keys(perColl).reduce((a, b) => ((perColl[a][hot] || 0) >= (perColl[b][hot] || 0) ? a : b));
const hotChunks = chunksOf(hotNs).filter(c => c.shard === hot);
print(`HOT: ${hot} (ratio ${ratio.toFixed(2)}), самая нагруженная коллекция ${hotNs}: ${perColl[hotNs][hot]} ops, чанков на шарде: ${hotChunks.length}`);
print(`Наименее нагруженный шард: ${cold}`);

if (!CFG.autoMove) {
  print("Режим отчёта: для автоматического переноса запустите с HOT_AUTO_MOVE=true");
  quit(2);
}

// Разгрузка: делим чанк горячей коллекции пополам и переносим верхнюю половину на холодный шард.
// За один запуск — не больше HOT_MAX_MOVES переносов, чтобы миграции не добавляли нагрузку на и так горячий шард.
let moves = 0;
for (const chunk of hotChunks) {
  if (moves >= CFG.maxMoves) break;
  try {
    db.adminCommand({ split: hotNs, bounds: [chunk.min, chunk.max] });
  } catch (e) {
    // Чанк из одного значения шард-ключа делить нельзя: ключ надо уточнить или поменять
    print(`  нельзя разделить ${EJSON.stringify(chunk.min)}: ${e.message}`);
    print(`  рекомендация: refineCollectionShardKey или reshardCollection для ${hotNs}`);
    continue;
  }
  const same = (a, b) => EJSON.stringify(a) === EJSON.stringify(b);
  const upper = chunksOf(hotNs).find(c => c.shard === hot && same(c.max, chunk.max));
  if (!upper || same(upper.min, chunk.min)) continue;
  print(`  moveRange ${hotNs} ${EJSON.stringify(upper.min)} .. ${EJSON.stringify(upper.max)}: ${hot} -> ${cold}`);
  const r = db.adminCommand({ moveRange: hotNs, min: upper.min, max: upper.max, toShard: cold });
  print(`  результат: ${r.ok ? "ok" : r.errmsg}`);
  if (r.ok) moves++;
}
print(`Перенесено диапазонов: ${moves}`);
quit(moves > 0 ? 3 : 2);
