# Portfolio 4: NoSQL and Advanced Data Models

**Case study:** PayBridge Microfinance Bank (see [Portfolio 1](../portfolio-1-database-design/README.md#1-case-study)). **Database:** MongoDB 7 in Docker, loaded from the Portfolio 1–2 PostgreSQL database.

## 1. Objective

Model the parts of the bank's data that do not need a strict relational ledger in a NoSQL document store, implement the model, and show where it fits better than PostgreSQL and where it does not. The money ledger stays in PostgreSQL. MongoDB holds:

- **Customer activity events:** logins, failed logins, transfers, KYC decisions and device changes, used by the app's activity feed and by fraud monitoring.
- **Customer profiles:** a read model for the app's profile screen.
- **Sessions:** short-lived login sessions, used as key-value data.

## 2. Files in this folder

| File | Purpose |
|---|---|
| [`export_events.sql`](export_events.sql) | Builds the activity events from PostgreSQL as MongoDB Extended JSON (read-only) |
| [`export_profiles.sql`](export_profiles.sql) | Builds one profile document per customer, with accounts and KYC history embedded (read-only) |
| [`setup.js`](setup.js) | Creates the three collections, the `$jsonSchema` validators and the TTL index |
| [`load.sh`](load.sh) | Starts the `mongo-bank` container, runs `setup.js` and streams both exports into `mongoimport` |
| [`01_documents.js`](01_documents.js) | Demo 1: the document model, event shapes and optional fields |
| [`02_validation.js`](02_validation.js) | Demo 2: flexible schema with validation, and `Decimal128` for money |
| [`03_queries.js`](03_queries.js) | Demo 3: queries on nested fields and arrays, and updates to embedded documents |
| [`04_aggregations.js`](04_aggregations.js) | Demo 4: aggregation pipelines, including account-takeover detection |
| [`05_indexes.js`](05_indexes.js) | Demo 5: `explain("executionStats")` before and after indexing |
| [`06_sessions.js`](06_sessions.js) | Demo 6: key-value lookups and automatic expiry with a TTL index |
| [`run_demos.sh`](run_demos.sh) | Reloads the data and runs every demo, writing `outputs/` |
| [`outputs/`](outputs/) | The output of the load and of every demo |
| [`screenshots/`](screenshots/) | The `run_demos.sh` run in the terminal |

## 3. How to run

From the repository root, with `pg-bank` running and the Portfolio 1 schema and Portfolio 2 seed loaded:

```bash
./portfolio-4-nosql/run_demos.sh
```

The script calls `load.sh` first, which creates the `mongo-bank` container on first use (MongoDB 7, listening on `127.0.0.1:27017` only, with this folder mounted read-only at `/p4`). It then recreates the MongoDB database, so every run starts from the same state. A full run takes about a minute, most of it demo 6 waiting for the TTL monitor.

No data files are stored in the repository. The exports are streamed from `psql` straight into `mongoimport`:

```bash
docker exec -i pg-bank psql -U postgres -d paybridge -X -q -At < export_events.sql \
  | docker exec -i mongo-bank mongoimport --db paybridge --collection activity_events
```

The data is deterministic. Transfer events come from the 50,000 seeded transfers (ids 1–50,000, so Portfolio 3 runs do not change them). Generated events use `setseed`, and KYC events are computed from `customer_id`. The only values that change between runs are the account balances in the profiles, which are a snapshot of PostgreSQL at load time.

## 4. Data model

### `activity_events`: 171,210 documents, one per event

| Event type | Documents | Comes from | Type-specific fields |
|---|---|---|---|
| `TRANSFER` | 50,000 | PostgreSQL `transfers`, with the sender's customer | `transfer` {id, accounts, amount, status}, `failure_reason` if failed, `reversal` if reversed |
| `LOGIN` | 92,174 | generated | `mfa` (mobile only) |
| `LOGIN_FAILED` | 8,026 | generated, plus a burst pattern for 25 customers | `failure_reason` |
| `KYC_UPDATE` | 17,985 | PostgreSQL `customers` (VERIFIED and REJECTED) | `kyc` {from/to status, document, reviewer, rejection reason} |
| `DEVICE_CHANGE` | 3,025 | generated | `old_device`, `new_device`, `verified_by` |

Every event has `type`, `customer_id`, `ts` and `channel`. The channel adds its own fields: `MOBILE` events carry a `device` {os, model, app version}, `WEB` events a `browser` and an `ip`, and `USSD` events a `ussd` {short code, phone} and no IP. A transfer made by USSD and one made in the app therefore have different shapes in the same collection, with no empty columns.

In PostgreSQL this would need either one wide table with many columns that are mostly NULL, or a table per event type plus a union for every timeline query. In MongoDB each event is stored as it happened, and a new event attribute (demo 2 adds a biometric face-match score) needs no schema change or migration.

### `customer_profiles`: 20,000 documents, one per customer

```text
{ _id: <customer_id>, full_name, contact: {email, phone}, joined_at,
  kyc: { status, history: [ {status, at, document, reviewed_by, rejection_reason?} ] },
  accounts: [ {account_id, account_no, type, currency, status, balance, opened_at} ],
  preferences?: {language, alerts: {sms, email}},  balance_as_of }
```

The profile screen needs the customer, all their accounts and their KYC status together. In PostgreSQL that is a join of `customers` and `accounts`. Here the accounts and KYC history are **embedded**, so the screen is one read by `_id`. Embedding suits this data because it is small and bounded (one to three accounts per customer) and is always read with its parent. Events are the opposite: unbounded and read on their own. So they are **referenced** by `customer_id` in a separate collection rather than embedded, which would let a profile grow without limit towards MongoDB's 16 MB document cap.

The cost of embedding is duplication: account balances and statuses now exist in two places. The profile is therefore a read model only. `balance_as_of` records when the snapshot was taken, PostgreSQL stays the source of truth, and in production the profile would be refreshed from PostgreSQL changes (for example through change data capture). Demo 3 makes this point explicitly.

### `sessions`: key-value

The key is the session token (`_id`) and the value is a small document. Every access is a lookup by key. A TTL index on `expires_at` makes MongoDB delete expired sessions itself. In a larger system this role would usually go to Redis; using MongoDB here shows the key-value access pattern without adding another product.

### Money and dates

Amounts are stored as `Decimal128` and timestamps as BSON dates, written by the export in MongoDB Extended JSON (`{"$numberDecimal": "26944.57"}`, `{"$date": "…"}`). Without this, `mongoimport` would turn amounts into binary floating-point numbers, which cannot represent most decimal amounts exactly. Demo 2 shows `0.1 + 0.2` giving `0.30000000000000004` as a double and `0.3` as `Decimal128`, and the validator rejects a transfer whose amount is a double.

## 5. Demonstrations

| # | Demo | What it shows | Evidence |
|---|---|---|---|
| 0 | Load | Container start, collections and validators created, 171,210 events and 20,000 profiles imported, all passing validation | [`outputs/00-load.txt`](outputs/00-load.txt) |
| 1 | Documents | Counts by type and channel, which optional fields each type carries, one example of each shape, a profile with embedded accounts | [`outputs/01-documents.txt`](outputs/01-documents.txt) |
| 2 | Validation | A new, unplanned field is accepted; a missing timestamp, an unknown event type and a floating-point amount are rejected with the rule that failed | [`outputs/02-validation.txt`](outputs/02-validation.txt) |
| 3 | Queries and updates | A customer's timeline, the profile in one read, a query into the accounts array, `$elemMatch`, a nested-field filter, `$set` + `$push` on the KYC history, the positional `$` update | [`outputs/03-queries.txt`](outputs/03-queries.txt) |
| 4 | Aggregations | Login failure rate by channel, transfer value by channel in `Decimal128`, failed transfers by reason, account-takeover detection with `$dateTrunc` and two `$lookup`s, `$unwind` over embedded accounts | [`outputs/04-aggregations.txt`](outputs/04-aggregations.txt) |
| 5 | Indexes | Three queries before and after an index, an index used for a query it was not designed for, index sizes, a multikey index | [`outputs/05-indexes.txt`](outputs/05-indexes.txt) |
| 6 | Sessions | Lookup by key (`IDHACK`), two sessions removed by the TTL monitor without any clean-up code | [`outputs/06-sessions.txt`](outputs/06-sessions.txt) |

## 6. Index results

Each query was run with only the default `_id` index, then again after creating one index. Each measured run follows a warm-up run.

| Query | Index | Before | After |
|---|---|---|---|
| Q1: latest 10 events for customer 800 | `{customer_id: 1, ts: -1}` | `COLLSCAN` + in-memory `SORT`, 171,210 documents examined | `IXSCAN`, 10 keys and 10 documents, no sort |
| Q2: failed logins in October 2026 (863) | `{type: 1, ts: 1}` | `COLLSCAN`, 171,210 documents examined | `IXSCAN`, 863 keys and 863 documents |
| Q3: profile owning account 23243 | `{"accounts.account_id": 1}`, unique, multikey | `COLLSCAN`, 20,000 documents examined | `IXSCAN`, 1 key and 1 document |

Times are in [`outputs/05-indexes.txt`](outputs/05-indexes.txt). They fell from tens of milliseconds to under one millisecond, but the documents-examined figures matter more: they grow with the collection without an index and stay constant with one.

## 7. Analysis

**Index design.** Q1's index follows MongoDB's equality–sort–range guideline: the equality field (`customer_id`) comes first and the sort field (`ts`) second. The matching entries are then already in timeline order, so the `SORT` stage disappears and the scan stops after 10 keys. Q2 puts `type` first for the same reason: within `LOGIN_FAILED`, October is one contiguous range of the index. Q4 shows the limit of an index. Asking for one customer's failed logins used `customer_ts`, but `type` is not in that index, so MongoDB examined all 24 of customer 800's events to return 8. That is cheap for one customer. If this query were frequent, `{customer_id: 1, type: 1, ts: -1}` would make it exact at the cost of another index. Q3's index is **multikey**: it holds one entry per embedded account, so it indexes 30,000 accounts across 20,000 documents. Declaring it unique also enforces that an account belongs to only one profile.

**Aggregation.** The account-takeover pipeline groups failed logins by customer and hour, keeps groups with five or more, and then uses two `$lookup` stages: one to fetch the customer's name, and one to check for a `DEVICE_CHANGE` within two hours. It found exactly the 25 seeded cases: eight failures from one unfamiliar IP, followed by a new device. No ordinary customer reached the threshold. This is the kind of query the fraud team would run over a log, and it runs over the same data the app uses for its activity feed.

**Why a document store suits this data.**
- *Varied shape:* five event types and three channels produce many shapes, which a fixed table would either flatten into NULLs or split across tables.
- *Access by aggregate:* the app reads "everything about this customer" (a profile, a timeline), which matches documents and embedded arrays.
- *Write pattern:* events are appended and never updated, so MongoDB's single-document atomicity is enough, and the collection can be sharded by `customer_id` as volume grows (Portfolio 5).
- *Tolerance of staleness:* a login event arriving a second late, or a profile balance a few minutes old, harms no one. The data can be eventually consistent, which is the BASE side of the trade-off.

**Why the ledger stays in PostgreSQL.** A transfer must debit one account, credit another and write two ledger rows atomically, with constraints and row locks (Portfolio 3). MongoDB can now run multi-document transactions, but it has no foreign keys or `CHECK` constraints across documents, and its design favours single-document operations. The profile duplicates balances on purpose. If it were the system of record, keeping copies consistent would become the application's job. The design is **polyglot persistence**: each store holds the data whose consistency needs match it.

## 8. Limitations

- Login and device events are generated, not real, so their distributions are uniform. The account-takeover pattern was inserted deliberately to test the detection pipeline.
- MongoDB runs as a single node without authentication, bound to localhost. Replication, write concerns and sharding are covered in Portfolio 5.
- The profile's balances are a snapshot taken at load time. No change-data-capture pipeline keeps them in sync.
- The TTL monitor runs once a minute, so expired sessions can remain for up to about 60 seconds. Code that checks a session must still compare `expires_at` with the current time.

## 9. Reflection

