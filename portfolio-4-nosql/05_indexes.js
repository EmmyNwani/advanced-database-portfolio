// MIT 8103 Portfolio 4, demo 5: indexes and explain("executionStats")
// Three queries are explained with only the default _id index, then again after adding one index each.

db = db.getSiblingDB("paybridge");

// Start from no secondary indexes, so the "before" plans are genuine
db.activity_events.dropIndexes();
db.customer_profiles.dropIndexes();

function planStages(node) {
  const stages = [];
  while (node) {
    stages.push(node.stage + (node.indexName ? "(" + node.indexName + ")" : ""));
    node = node.inputStage || (node.inputStages ? node.inputStages[0] : null);
  }
  return stages.join(" <- ");
}

function report(label, explain) {
  const s = explain.executionStats;
  const wp = explain.queryPlanner.winningPlan;
  print(label.padEnd(8) + "plan: " + planStages(wp.queryPlan || wp));
  print("        returned " + s.nReturned + ", keys examined " + s.totalKeysExamined +
        ", documents examined " + s.totalDocsExamined + ", time " + s.executionTimeMillis + " ms");
}

const queries = [
  {
    name: "Q1: customer timeline  find({customer_id: 800}).sort({ts: -1}).limit(10)",
    run: () => db.activity_events.find({ customer_id: 800 }).sort({ ts: -1 }).limit(10).explain("executionStats"),
    index: () => db.activity_events.createIndex({ customer_id: 1, ts: -1 }, { name: "customer_ts" })
  },
  {
    name: "Q2: failed logins in October 2026  find({type: 'LOGIN_FAILED', ts: {$gte, $lt}})",
    run: () => db.activity_events.find({ type: "LOGIN_FAILED",
                 ts: { $gte: ISODate("2026-10-01"), $lt: ISODate("2026-11-01") } }).explain("executionStats"),
    index: () => db.activity_events.createIndex({ type: 1, ts: 1 }, { name: "type_ts" })
  },
  {
    name: "Q3: owner of an account  find({'accounts.account_id': 23243})",
    run: () => db.customer_profiles.find({ "accounts.account_id": 23243 }).explain("executionStats"),
    index: () => db.customer_profiles.createIndex({ "accounts.account_id": 1 }, { name: "account_id", unique: true })
  }
];

for (const q of queries) {
  print("=== " + q.name);
  q.run();                         // warm-up, so both runs read from memory
  report("before", q.run());
  print("        index created: " + q.index());
  q.run();
  report("after", q.run());
  print("");
}

print("=== Does Q1's index also serve Q4 (customer's events of one type)?");
report("Q4", db.activity_events.find({ customer_id: 800, type: "LOGIN_FAILED" }).sort({ ts: -1 }).explain("executionStats"));

print("\n=== Index sizes (bytes)");
for (const c of ["activity_events", "customer_profiles"]) {
  const st = db[c].stats();
  print(c + ": documents " + st.count + ", data " + st.size + ", storage " + st.storageSize);
  for (const [name, size] of Object.entries(st.indexSizes)) print("  " + name.padEnd(12) + size);
}
print("\n=== Multikey: the account_id index has one entry per embedded account");
let node = db.customer_profiles.find({ "accounts.account_id": 23243 }).explain().queryPlanner.winningPlan;
node = node.queryPlan || node;
while (node && node.stage !== "IXSCAN") node = node.inputStage;
print("index " + node.indexName + ", isMultiKey: " + node.isMultiKey + ", multiKeyPaths: " + JSON.stringify(node.multiKeyPaths));
