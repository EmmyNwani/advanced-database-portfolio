// MIT 8103 Portfolio 4, demo 6: key-value access with automatic expiry
// sessions is used as a key-value store: the key is the session token (_id), the value a small document.
// The TTL index created in setup.js removes each session once expires_at has passed.
// MongoDB's TTL monitor runs every 60 seconds, so this demo waits up to about two minutes.

db = db.getSiblingDB("paybridge");
db.sessions.deleteMany({});

const now = new Date();
const plus = (sec) => new Date(now.getTime() + sec * 1000);

db.sessions.insertMany([
  { _id: "tok-7f3a9c", customer_id: 800,  channel: "MOBILE", created_at: now, expires_at: plus(5) },
  { _id: "tok-b21e44", customer_id: 1600, channel: "WEB",    created_at: now, expires_at: plus(5) },
  { _id: "tok-c90d17", customer_id: 4,    channel: "MOBILE", created_at: now, expires_at: plus(3600) }
]);

print("=== TTL index");
printjson(db.sessions.getIndexes().find(i => i.name === "ttl_expires_at"));

print("\n=== GET by key: one lookup on the _id index");
printjson(db.sessions.findOne({ _id: "tok-7f3a9c" }));
const e = db.sessions.find({ _id: "tok-7f3a9c" }).explain("executionStats");
print("plan: " + (e.queryPlanner.winningPlan.queryPlan || e.queryPlanner.winningPlan).stage +
      ", documents examined " + e.executionStats.totalDocsExamined);

print("\n=== Two sessions expire after 5 seconds, one after an hour. Waiting for the TTL monitor...");
print("0 s: " + db.sessions.countDocuments() + " sessions");
let waited = 0;
while (db.sessions.countDocuments() > 1 && waited < 150) { sleep(5000); waited += 5; }
print(waited + " s: " + db.sessions.countDocuments() + " session(s) left: " +
      db.sessions.find({}, { _id: 1 }).toArray().map(d => d._id).join(", "));
print("The expired sessions were deleted by the database itself; no clean-up job was needed.");
