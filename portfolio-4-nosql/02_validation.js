// MIT 8103 Portfolio 4, demo 2: flexible schema with validation
// New optional fields are accepted without any schema change; documents that break the rules are rejected.

db = db.getSiblingDB("paybridge");

function tryInsert(label, doc) {
  print("\n--- " + label);
  try {
    db.activity_events.insertOne(doc);
    print("ACCEPTED: " + doc._id);
  } catch (e) {
    const rules = e.errInfo && e.errInfo.details ? e.errInfo.details.schemaRulesNotSatisfied : null;
    print("REJECTED: " + e.message.split(":")[0]);
    if (rules) print("  rules not satisfied: " + JSON.stringify(rules));
  }
}

print("=== Validator on activity_events");
printjson(db.getCollectionInfos({ name: "activity_events" })[0].options.validator);

tryInsert("A new field nobody planned for (biometric login with a face-match score)", {
  _id: "DEMO-1", type: "LOGIN", customer_id: 4, ts: new Date("2026-11-01T09:00:00Z"), channel: "MOBILE",
  device: { os: "iOS", model: "iPhone 15", app_version: "4.3.0" },
  mfa: "BIOMETRIC", biometric: { method: "FACE", match_score: 0.97 }
});

tryInsert("Missing the timestamp", {
  _id: "DEMO-2", type: "LOGIN", customer_id: 4, channel: "WEB"
});

tryInsert("Unknown event type", {
  _id: "DEMO-3", type: "PASSWORD_RESET", customer_id: 4, ts: new Date(), channel: "WEB"
});

tryInsert("Transfer amount stored as a floating-point number instead of Decimal128", {
  _id: "DEMO-4", type: "TRANSFER", customer_id: 4, ts: new Date(), channel: "WEB",
  transfer: { transfer_id: 99999, amount: 1000.10, status: "COMPLETED" }
});

tryInsert("The same transfer with the amount as Decimal128", {
  _id: "DEMO-5", type: "TRANSFER", customer_id: 4, ts: new Date("2026-11-01T09:05:00Z"), channel: "WEB",
  transfer: { transfer_id: 99999, amount: NumberDecimal("1000.10"), status: "COMPLETED" }
});

print("\n=== Why Decimal128 matters for money");
print("double:     0.1 + 0.2 = " + (0.1 + 0.2));
print("Decimal128: 0.1 + 0.2 = " + db.activity_events.aggregate([
  { $limit: 1 }, { $project: { _id: 0, s: { $add: [NumberDecimal("0.1"), NumberDecimal("0.2")] } } }
]).toArray()[0].s);

print("\n=== Clean up the demo documents");
print("deleted: " + db.activity_events.deleteMany({ _id: /^DEMO-/ }).deletedCount);
