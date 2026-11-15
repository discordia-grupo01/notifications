// Datos de prueba locales para el test de contrato (mongosh, base efimera).
// Un servidor del que el usuario de prueba es dueño, con un canal de texto, para que
// PUT /settings/servers/{id} y /settings/channels/{id} lleguen al 200.
// Idempotente: se puede correr varias veces contra la misma base.
const user = "00000000-0000-4000-8000-000000000001";
const server = "00000000-0000-4000-8000-0000000000a1";
const channel = "00000000-0000-4000-8000-0000000000b1";

const upsert = (collection, doc) =>
  db.getCollection(collection).replaceOne({ _id: doc._id }, doc, { upsert: true });

upsert("replica_servers", { _id: server, owner_id: user });
upsert("replica_members", {
  _id: `${server}:${user}`,
  user_id: user,
  server_id: server,
  role_ids: [],
  joined_at: new Date("2026-01-01T00:00:00Z"),
});
upsert("channels", { _id: channel, server_id: server, kind: "text" });

// Cada corrida arranca sin dispositivos push: el limite es de 10 por usuario y la base
// conserva los de la corrida anterior, con lo que POST /push/devices daria 409 DEVICE_LIMIT.
db.getCollection("push_devices").deleteMany({ user_id: user });
