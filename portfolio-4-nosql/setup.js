// MIT 8103 Portfolio 4: create the collections, with schema validation
// Run by load.sh before the import. Drops and recreates the paybridge database in MongoDB.

db = db.getSiblingDB("paybridge");
db.dropDatabase();

// activity_events: flexible, but every event must have the fields every query relies on.
// Fields that depend on the event type or channel (device, browser, ussd, transfer, kyc, ...)
// are optional, and new fields can be added without changing the validator.
db.createCollection("activity_events", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["type", "customer_id", "ts", "channel"],
      properties: {
        type: {
          enum: ["TRANSFER", "LOGIN", "LOGIN_FAILED", "KYC_UPDATE", "DEVICE_CHANGE"],
          description: "one of the known event types"
        },
        customer_id: { bsonType: ["int", "long"], minimum: 1 },
        ts: { bsonType: "date" },
        channel: { enum: ["MOBILE", "WEB", "USSD", "BRANCH"] },
        transfer: {
          bsonType: "object",
          required: ["transfer_id", "amount", "status"],
          properties: { amount: { bsonType: "decimal" } }
        }
      }
    }
  },
  validationLevel: "strict",
  validationAction: "error"
});

// customer_profiles: _id is the PostgreSQL customer_id
db.createCollection("customer_profiles", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "full_name", "contact", "kyc", "accounts"],
      properties: {
        _id: { bsonType: ["int", "long"] },
        kyc: {
          bsonType: "object",
          required: ["status", "history"],
          properties: { status: { enum: ["PENDING", "VERIFIED", "REJECTED"] } }
        },
        accounts: {
          bsonType: "array",
          minItems: 1,
          items: {
            bsonType: "object",
            required: ["account_id", "type", "status", "balance"],
            properties: { balance: { bsonType: "decimal" } }
          }
        }
      }
    }
  }
});

// sessions: key-value use of MongoDB. _id is the session token, the value is a small document,
// and a TTL index deletes each session automatically once expires_at has passed.
db.createCollection("sessions");
db.sessions.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0, name: "ttl_expires_at" });

print("Collections: " + db.getCollectionNames().sort().join(", "));
