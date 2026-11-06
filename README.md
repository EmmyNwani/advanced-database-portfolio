# MIT 8103 Advanced Database Systems Portfolio

**Student:** Ugochukwu Emmanuel Nwani

**Student ID:** 301930571

**Programme:** Master of Information Technology, MIVA Open University (2026/2027, First Semester CA) 

**Case study:** PayBridge Microfinance Bank, a simulated digital bank

This repository holds the practical evidence for all five portfolio activities. The final 2–3 page summary is submitted with it as `Nwani_Ugochukwu_301930571_README.pdf`. Everything uses one case study consistently: a bank where the ledger needs strict ACID guarantees, while data that tolerates eventual consistency is modelled separately.

## 1. Case study summary

PayBridge is a simulated digital microfinance bank. Customers open savings and current accounts, deposit and withdraw, and transfer funds to other accounts. Tellers, support staff and auditors also use the data.

- **Major data:** customers (with KYC status), account types, accounts and balances, transfers, ledger transactions, audit log.
- **Key operations:** open accounts, deposit, withdraw, transfer funds, reverse failed transfers, produce statements, audit balances.
- **Why this case study:** transfers give a natural example for transactions and concurrency, the activity logs suit a document store, and a bank's growth path raises real replication, sharding and consistency questions.

Full statement: [`portfolio-1-database-design/README.md`](portfolio-1-database-design/README.md).

## 2. Technology choices

| Area | Technology | Reason |
|---|---|---|
| Ledger (Portfolios 1-3) | PostgreSQL 16 in Docker | Full ACID, serializable isolation available, mature planner and `EXPLAIN` tooling |
| NoSQL (Portfolio 4) | MongoDB 7 in Docker | Flexible documents for customer activity events and profiles, plus a key-value session store with a TTL index, where eventual consistency is acceptable |
| Distributed (Portfolio 5) | PostgreSQL 16 primary + streaming replica, and a three-member MongoDB replica set (Docker Compose) | Demonstrates replication, synchronous vs asynchronous commit, failover, split brain and the consistency/availability trade-off. Sharding is analysed on the seeded data, and the README places Citus and NewSQL systems such as CockroachDB on the growth path for scaling writes beyond one primary |

The guiding principle is polyglot persistence: the money ledger stays ACID in PostgreSQL, and only data that tolerates BASE-style behaviour moves to NoSQL.

## 3. Repository structure

```
advanced-database-portfolio/
├── portfolio-1-database-design/        ER diagram, schema, constraints, normalisation
├── portfolio-2-query-optimisation/     seed data, benchmark queries, indexes, execution plans
├── portfolio-3-transactions-concurrency/ atomic transfer, audit trigger, commit, rollback and concurrency demos
├── portfolio-4-nosql/                  MongoDB document model, validation, queries, aggregations, indexes
├── portfolio-5-distributed-cloud/      replication, failover, MongoDB replica set, sharding, cloud plan
└── README.md
```

Each folder has its own README explaining how that activity was implemented and tested.

## 4. Progress and evidence

| Portfolio | Topic | Where to look |
|---|---|---|
| 1 | Database design and modelling | `portfolio-1-database-design/` (`er-diagram/`, `schema.sql`, normalisation in README, `screenshots/`, `outputs/`) |
| 2 | Query processing and optimisation | `portfolio-2-query-optimisation/` (`seed.sql`, `queries.sql`, `indexes.sql`, `q5_rewrite.sql`, `plans/`, `outputs/`) |
| 3 | Transactions and concurrency | `portfolio-3-transactions-concurrency/` (`transfer_funds.sql`, `audit_trigger.sql`, `01_commit.sql`, `02_rollback.sql`, `concurrency_demos.sh`, `outputs/`) |
| 4 | NoSQL and advanced data models | `portfolio-4-nosql/` (`export_events.sql`, `export_profiles.sql`, `setup.js`, `load.sh`, `01_documents.js` to `06_sessions.js`, `run_demos.sh`, `outputs/`) |
| 5 | Distributed and cloud databases | `portfolio-5-distributed-cloud/` (`docker-compose.yml`, `primary-init.sh`, `replica-entrypoint.sh`, `run_demos.sh`, `sharding_analysis.sql`, `outputs/`) |

### Portfolio summaries

**Portfolio 1: Database design and modelling.** Relational design for the bank in 3NF with deliberate, documented denormalisation (`accounts.balance`, `transactions.balance_after`). Money is stored as `NUMERIC(15,2)`, business rules are enforced with `CHECK`, foreign key and unique constraints, and secondary indexes are intentionally left out for Portfolio 2.

**Portfolio 2: Query processing and optimisation.** Reproducible seed data (20,000 customers, 30,000 accounts, 50,000 transfers, 190,800 ledger rows) and six benchmark queries measured with `EXPLAIN (ANALYZE, BUFFERS)` before and after six targeted indexes, including two partial indexes and one covering index. Selective lookups improved 48× to 1,000×; join- and aggregation-heavy queries gained little, and the window-function index went unused. The slowest query, a correlated subquery, fell from 47,299 ms to 47 ms with indexes and to 19.5 ms when rewritten as a single `GROUP BY`.

**Portfolio 3: Transactions and concurrency.** An atomic `transfer_funds` function locks both accounts in `account_id` order, checks seven guardrails (amount, distinct accounts, existence, status, currency, minimum balance, daily limit) and writes the transfer, both balances and both ledger rows in one transaction, with an audit trigger recording every balance change. Eight demos, six of them run as two real concurrent sessions, show commit, rollback, an aborted transaction, `SAVEPOINT`, a lost update and its prevention with `SELECT … FOR UPDATE`, a deadlock and its prevention by lock ordering, and the difference between `READ COMMITTED` and `REPEATABLE READ`.

**Portfolio 4: NoSQL and advanced data models.** MongoDB 7 holds the data that does not need the ledger's guarantees, loaded straight from PostgreSQL: 171,210 customer activity events of five types whose shape varies by type and channel, 20,000 customer profiles with accounts and KYC history embedded, and a key-value session store with a TTL index. `$jsonSchema` validation accepts new fields but rejects malformed events and non-`Decimal128` money. Indexes cut the documents examined from 171,210 to 10 for a customer timeline and from 20,000 to 1 for an account lookup, and an aggregation pipeline detects 25 account-takeover patterns. The README argues why a document model suits this data and why the ledger stays relational.

**Portfolio 5: Distributed and cloud databases.** A Docker Compose cluster with a PostgreSQL primary and streaming replica and a three-member MongoDB replica set. Ten demos show replication, a read-only replica, a stale read under asynchronous replication, a commit blocked by synchronous replication while the standby is down, manual failover with `pg_promote()`, split brain when the old primary is not fenced, and MongoDB majority writes, step-down and re-election. A sharding analysis shows that hashing `customer_id` spreads the data evenly while range sharding creates a hot shard, and that 66.5% of transfers would cross shards. The README relates the results to CAP and PACELC and proposes a managed cloud deployment.

## 5. How to reproduce

Requirements: Docker, and `psql` (or use `docker exec` as below).

```bash
# 1. Start PostgreSQL
docker run --name pg-bank -e POSTGRES_PASSWORD=<your_password> \
  -p 5432:5432 -d postgres:16

# 2. Create the database
docker exec -it pg-bank psql -U postgres -c "CREATE DATABASE paybridge;"

# 3. Portfolio 1: load the schema
docker exec -i pg-bank psql -U postgres -d paybridge \
  < portfolio-1-database-design/schema.sql

# 4. Portfolio 2: load seed data, then follow portfolio-2-query-optimisation/README.md
docker exec -i pg-bank psql -U postgres -d paybridge \
  < portfolio-2-query-optimisation/seed.sql

# 5. Portfolio 3: follow portfolio-3-transactions-concurrency/README.md

# 6. Portfolio 4: start MongoDB, load it from PostgreSQL and run the demos
./portfolio-4-nosql/run_demos.sh

# 7. Portfolio 5: build the replicated cluster and run the demos
./portfolio-5-distributed-cloud/run_demos.sh
```

Then follow the README inside each portfolio folder. Do not commit passwords; use a placeholder or an ignored `.env` file.

## 6. Technical reflection

### Why ACID for the ledger

ACID is used for the ledger to ensure that transaction data stays **Atomic, Consistent, Isolated, and Durable**, maintaining data integrity and reliability.

### Challenges

One of the challenges encountered was starting PostgreSQL using Docker.

#### Starting PostgreSQL in Docker

Error:

```text
$ docker run --name pg-bank -e POSTGRES_PASSWORD=<your_password> \
  -p 5432:5432 -d postgres:16

failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory
```

Fix: start Docker Desktop, confirm the daemon is running, then run the container again.

```bash
open -a Docker

docker info

# After confirming Docker was running:

docker run --name pg-bank -e POSTGRES_PASSWORD=<your_password> \
  -p 5432:5432 -d postgres:16

# Expected output: container ID
```

## 7. AI use declaration

- **Tool(s) used:** Claude (Anthropic).
- **Used for:** planning the work schedule, discussing the SQL vs NewSQL vs NoSQL design choices, and drafting starter versions of the schema, seed, query and index scripts and README text.
- **How I reviewed and verified:** I ran every script myself against PostgreSQL 16, checked the constraints with deliberate bad inserts, captured my own execution plans, modified the drafts to fit my design decisions, and wrote the analysis and reflection myself.

## 8. References

- Abadi, D. (2012). Consistency tradeoffs in modern distributed database system design: CAP is only part of the story. *IEEE Computer*, 45(2), 37–42.
- Brewer, E. (2000). Towards robust distributed systems. Keynote, *ACM Symposium on Principles of Distributed Computing (PODC)*.
- Elmasri, R. and Navathe, S. B. (2016). *Fundamentals of Database Systems* (7th ed.). Pearson.
- Gilbert, S. and Lynch, N. (2002). Brewer's conjecture and the feasibility of consistent, available, partition-tolerant web services. *ACM SIGACT News*, 33(2), 51–59.
- Kleppmann, M. (2017). *Designing Data-Intensive Applications*. O'Reilly Media.
- PostgreSQL Global Development Group. *PostgreSQL 16 Documentation*: Using EXPLAIN (https://www.postgresql.org/docs/16/using-explain.html), Partial Indexes (https://www.postgresql.org/docs/16/indexes-partial.html), Transaction Isolation (https://www.postgresql.org/docs/16/transaction-iso.html), Explicit Locking (https://www.postgresql.org/docs/16/explicit-locking.html), High Availability, Load Balancing, and Replication (https://www.postgresql.org/docs/16/high-availability.html).
- MongoDB, Inc. *MongoDB Manual*: Schema Validation (https://www.mongodb.com/docs/manual/core/schema-validation/), TTL Indexes (https://www.mongodb.com/docs/manual/core/index-ttl/), Replication (https://www.mongodb.com/docs/manual/replication/), Write Concern (https://www.mongodb.com/docs/manual/reference/write-concern/), Sharding (https://www.mongodb.com/docs/manual/sharding/).
- Docker Inc. *Docker Compose documentation*: https://docs.docker.com/compose/
- MIT 8103 Advanced Database Systems course materials, MIVA Open University.