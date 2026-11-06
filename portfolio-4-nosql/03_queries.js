// MIT 8103 Portfolio 4, demo 3: queries and updates
// Reads that match how the app uses the data, and updates on embedded documents.

db = db.getSiblingDB("paybridge");

print("=== Q1: activity timeline for customer 800 (latest 10 events, selected fields)");
db.activity_events.find(
  { customer_id: 800 },
  { _id: 0, ts: 1, type: 1, channel: 1, "location.city": 1, failure_reason: 1, "transfer.amount": 1, "transfer.status": 1 }
).sort({ ts: -1 }).limit(10).forEach(d => print(JSON.stringify(d)));

print("\n=== Q2: the profile screen, one read by _id, no joins");
printjson(db.customer_profiles.findOne({ _id: 800 }, { full_name: 1, "kyc.status": 1, accounts: 1 }));

print("\n=== Q3: who owns account 23243? (query inside the embedded accounts array)");
printjson(db.customer_profiles.findOne({ "accounts.account_id": 23243 }, { full_name: 1, "accounts.$": 1 }));

print("\n=== Q4: customers holding a FROZEN CURRENT account ($elemMatch: both conditions on the same account)");
print("with $elemMatch:    " + db.customer_profiles.countDocuments(
  { accounts: { $elemMatch: { type: "CURRENT", status: "FROZEN" } } }));
print("without $elemMatch: " + db.customer_profiles.countDocuments(
  { "accounts.type": "CURRENT", "accounts.status": "FROZEN" }) +
  "  (also matches a customer with a CURRENT account and a different, FROZEN account)");

print("\n=== Q5: mobile logins on Android app versions older than 4.1 in October 2026 (nested field)");
print(db.activity_events.countDocuments({
  type: "LOGIN", "device.os": "Android", "device.app_version": { $lt: "4.1" },
  ts: { $gte: ISODate("2026-10-01"), $lt: ISODate("2026-11-01") }
}) + " logins");

print("\n=== U1: a REJECTED customer is re-verified: change status and append to the embedded history");
const rejected = db.customer_profiles.findOne({ "kyc.status": "REJECTED" }, { _id: 1 })._id;
print("customer " + rejected + " before:");
printjson(db.customer_profiles.findOne({ _id: rejected }, { _id: 0, kyc: 1 }));
const u1 = db.customer_profiles.updateOne(
  { _id: rejected },
  { $set: { "kyc.status": "VERIFIED" },
    $push: { "kyc.history": { status: "VERIFIED", at: ISODate("2026-11-02T10:00:00Z"),
                              document: "NIN", reviewed_by: "officer-07" } } }
);
print("matched " + u1.matchedCount + ", modified " + u1.modifiedCount + "; after:");
printjson(db.customer_profiles.findOne({ _id: rejected }, { _id: 0, kyc: 1 }));

print("\n=== U2: freeze one embedded account with the positional $ operator");
const u2 = db.customer_profiles.updateOne(
  { "accounts.account_id": 23243 },
  { $set: { "accounts.$.status": "FROZEN" } }
);
print("matched " + u2.matchedCount + ", modified " + u2.modifiedCount);
printjson(db.customer_profiles.findOne({ "accounts.account_id": 23243 }, { _id: 1, "accounts.$": 1 }));
print("Note: this changes only the profile copy. The account's real status lives in PostgreSQL;");
print("in production the change would be made there first and propagated to the profile.");
