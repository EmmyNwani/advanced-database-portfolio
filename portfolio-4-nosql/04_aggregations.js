// MIT 8103 Portfolio 4, demo 4: aggregation pipelines
// Reports the bank's operations and fraud teams would run over the activity log.

db = db.getSiblingDB("paybridge");

print("=== A1: login failure rate by channel (all time)");
db.activity_events.aggregate([
  { $match: { type: { $in: ["LOGIN", "LOGIN_FAILED"] } } },
  { $group: { _id: "$channel",
              attempts: { $sum: 1 },
              failed: { $sum: { $cond: [{ $eq: ["$type", "LOGIN_FAILED"] }, 1, 0] } } } },
  { $project: { attempts: 1, failed: 1,
                failure_rate_pct: { $round: [{ $multiply: [{ $divide: ["$failed", "$attempts"] }, 100] }, 2] } } },
  { $sort: { _id: 1 } }
]).forEach(r => print(JSON.stringify(r)));

print("\n=== A2: transfers by channel: count, value and failure rate (amounts summed as Decimal128)");
db.activity_events.aggregate([
  { $match: { type: "TRANSFER" } },
  { $group: { _id: "$channel",
              transfers: { $sum: 1 },
              total_value: { $sum: "$transfer.amount" },
              average: { $avg: "$transfer.amount" },
              failed: { $sum: { $cond: [{ $eq: ["$transfer.status", "FAILED"] }, 1, 0] } } } },
  { $project: { transfers: 1, total_value: 1, average: { $round: ["$average", 2] },
                failed_pct: { $round: [{ $multiply: [{ $divide: ["$failed", "$transfers"] }, 100] }, 2] } } },
  { $sort: { total_value: -1 } }
]).forEach(r => print(JSON.stringify(r)));

print("\n=== A3: failed transfers by reason and channel, October 2026");
db.activity_events.aggregate([
  { $match: { type: "TRANSFER", "transfer.status": "FAILED",
              ts: { $gte: ISODate("2026-10-01"), $lt: ISODate("2026-11-01") } } },
  { $group: { _id: { reason: "$failure_reason", channel: "$channel" }, n: { $sum: 1 } } },
  { $sort: { "_id.reason": 1, "_id.channel": 1 } }
]).forEach(r => print(JSON.stringify(r)));

print("\n=== A4: possible account takeover: 5 or more failed logins in one hour, October 2026,");
print("    with the customer's name ($lookup to profiles) and any device change within 2 hours");
db.activity_events.aggregate([
  { $match: { type: "LOGIN_FAILED", ts: { $gte: ISODate("2026-10-01"), $lt: ISODate("2026-11-01") } } },
  { $group: { _id: { customer_id: "$customer_id", hour: { $dateTrunc: { date: "$ts", unit: "hour" } } },
              failures: { $sum: 1 }, ips: { $addToSet: "$ip" }, last_failure: { $max: "$ts" } } },
  { $match: { failures: { $gte: 5 } } },
  { $lookup: { from: "customer_profiles", localField: "_id.customer_id", foreignField: "_id", as: "profile" } },
  { $lookup: { from: "activity_events",
               let: { cid: "$_id.customer_id", t: "$last_failure" },
               pipeline: [
                 { $match: { $expr: { $and: [
                     { $eq: ["$customer_id", "$$cid"] },
                     { $eq: ["$type", "DEVICE_CHANGE"] },
                     { $gte: ["$ts", "$$t"] },
                     { $lte: ["$ts", { $dateAdd: { startDate: "$$t", unit: "hour", amount: 2 } }] } ] } } },
                 { $project: { _id: 0, ts: 1, new_device: 1 } } ],
               as: "device_change" } },
  { $project: { _id: 0, customer_id: "$_id.customer_id", name: { $first: "$profile.full_name" },
                hour: "$_id.hour", failures: 1, ips: 1,
                device_changed_after: { $gt: [{ $size: "$device_change" }, 0] } } },
  { $sort: { hour: 1 } }
]).forEach(r => print(JSON.stringify(r)));

print("\n=== A5: accounts and balances by customer KYC status and account type ($unwind over the embedded array)");
db.customer_profiles.aggregate([
  { $unwind: "$accounts" },
  { $group: { _id: { kyc: "$kyc.status", type: "$accounts.type" },
              accounts: { $sum: 1 }, balance: { $sum: "$accounts.balance" } } },
  { $sort: { "_id.kyc": 1, "_id.type": 1 } }
]).forEach(r => print(JSON.stringify(r)));
