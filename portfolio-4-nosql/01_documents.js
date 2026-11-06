// MIT 8103 Portfolio 4, demo 1: the document model
// One collection holds five event types with different shapes; profiles embed accounts and KYC history.

db = db.getSiblingDB("paybridge");

print("=== Collections and document counts");
for (const c of ["activity_events", "customer_profiles", "sessions"]) {
  print(c.padEnd(20) + db[c].countDocuments());
}

print("\n=== activity_events by type and channel");
db.activity_events.aggregate([
  { $group: { _id: { type: "$type", channel: "$channel" }, n: { $sum: 1 } } },
  { $sort: { "_id.type": 1, "_id.channel": 1 } }
]).forEach(r => print(r._id.type.padEnd(15) + r._id.channel.padEnd(8) + String(r.n).padStart(7)));

print("\n=== Which optional fields each event type carries (count of documents with the field)");
const fields = ["device", "browser", "ussd", "ip", "location", "transfer", "failure_reason",
                "reversal", "mfa", "kyc", "old_device", "new_device", "verified_by"];
db.activity_events.aggregate([
  { $group: Object.assign({ _id: "$type" },
      Object.fromEntries(fields.map(f => [f, { $sum: { $cond: [{ $ne: [{ $type: "$" + f }, "missing"] }, 1, 0] } }]))) },
  { $sort: { _id: 1 } }
]).forEach(r => print(r._id.padEnd(15) + fields.filter(f => r[f] > 0).map(f => f + "=" + r[f]).join("  ")));

print("\n=== One example of each shape");
const examples = [
  ["TRANSFER via MOBILE",        { type: "TRANSFER", channel: "MOBILE" }],
  ["TRANSFER via USSD (FAILED)", { type: "TRANSFER", channel: "USSD", "transfer.status": "FAILED" }],
  ["TRANSFER (REVERSED)",        { type: "TRANSFER", "transfer.status": "REVERSED" }],
  ["LOGIN via WEB",              { type: "LOGIN", channel: "WEB" }],
  ["LOGIN_FAILED via MOBILE",    { type: "LOGIN_FAILED", channel: "MOBILE" }],
  ["KYC_UPDATE (REJECTED)",      { type: "KYC_UPDATE", "kyc.to_status": "REJECTED" }],
  ["DEVICE_CHANGE",              { type: "DEVICE_CHANGE" }]
];
for (const [label, filter] of examples) {
  print("\n--- " + label);
  printjson(db.activity_events.findOne(filter));
}

print("\n=== A customer profile: accounts and KYC history embedded, preferences optional");
printjson(db.customer_profiles.findOne({ _id: 4 }));
print("\n--- Profiles with and without the optional preferences field");
print("with preferences:    " + db.customer_profiles.countDocuments({ preferences: { $exists: true } }));
print("without preferences: " + db.customer_profiles.countDocuments({ preferences: { $exists: false } }));
print("\n--- Profiles by number of embedded accounts");
db.customer_profiles.aggregate([
  { $group: { _id: { $size: "$accounts" }, customers: { $sum: 1 } } }, { $sort: { _id: 1 } }
]).forEach(r => print(r._id + " account(s): " + r.customers + " customers"));
