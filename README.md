# MIT 8103 Advanced Database Systems Portfolio

**Student:** Emmanuel Ugochukwu Nwani
**Programme:** Master of Information Technology, MIVA Open University (2026/2027, First Semester CA)
**Case study:** PayBridge Microfinance Bank, a simulated digital bank

This repository holds the practical evidence for all five portfolio activities plus the final documentation. Everything uses one case study consistently: a bank where the ledger needs strict ACID guarantees, while data that tolerates eventual consistency is modelled separately.

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
| NoSQL (Portfolio 4) | MongoDB | Flexible documents for activity/transaction logs, where eventual consistency is acceptable |
| Distributed (Portfolio 5) | PostgreSQL primary + replica (Docker Compose) | Demonstrates replication, failover and the consistency/availability trade-off. A NewSQL system such as CockroachDB is a possible extension so as to model a distributed database setup that allows for scalability|

The guiding principle is polyglot persistence: the money ledger stays ACID in PostgreSQL, and only data that tolerates BASE-style behaviour moves to NoSQL.

## 3. Repository structure

```
advanced-database-portfolio/
├── portfolio-1-database-design/        ER diagram, schema, constraints, normalisation
├── portfolio-2-query-optimisation/     seed data, queries, execution plans, indexes
├── portfolio-3-transactions-concurrency/
├── portfolio-4-nosql/
├── portfolio-5-distributed-cloud/
└── README.md
```

Each folder has its own README explaining how that activity was implemented and tested.

## 4. Progress and evidence

| Portfolio | Topic | Status | Where to look |
|---|---|---|---|
| 1 | Database design and modelling | Complete | `portfolio-1-database-design/` (ER diagram, `schema.sql`, normalisation notes, screenshots) |
| 2 | Query processing and optimisation | In progress | `portfolio-2-query-optimisation/` (`seed.sql`, `queries.sql`, `indexes.sql`, before/after plans) |
| 3 | Transactions and concurrency | Planned | `portfolio-3-transactions-concurrency/` |
| 4 | NoSQL and advanced data models | Planned | `portfolio-4-nosql/` |
| 5 | Distributed and cloud database | Planned | `portfolio-5-distributed-cloud/` |

### Portfolio summaries

**Portfolio 1: Database design and modelling.** Relational design for the bank in 3NF with deliberate, documented denormalisation (`accounts.balance`, `transactions.balance_after`). Money is stored as `NUMERIC(15,2)`, business rules are enforced with `CHECK`, foreign key and unique constraints, and secondary indexes are intentionally left out for Portfolio 2.

**Portfolio 2: Query processing and optimisation.** Seed data of roughly 20,000 customers, 30,000 accounts, 50,000 transfers and 190,000 transactions. Six benchmark queries covering point lookups, joins, aggregation and a window function. Execution plans are captured with `EXPLAIN (ANALYZE, BUFFERS)` before and after adding indexes, with a short analysis of each result.

| Query | Before (plan, ms) | After (plan, ms) | Notes |
|---|---|---|---|
| Q1 account statement | | | |
| Q2 customer balances | | | |
| Q3 recent transfers | | | |
| Q4 top senders | | | |
| Q5 failed transfers per customer | | | |
| Q6 balance ranking | | | |

**Portfolio 3: Transactions and concurrency.** *Planned:* fund-transfer transactions showing commit and rollback, isolation level behaviour, a concurrency anomaly such as a lost update or deadlock reproduced with two sessions, and the control mechanism that fixes it.

**Portfolio 4: NoSQL and advanced data models.** *Planned:* the same bank modelled in MongoDB for transaction and activity logs, with queries, indexing, and an argument for why this data tolerates eventual consistency while the ledger does not.

**Portfolio 5: Distributed and cloud database.** *Planned:* PostgreSQL primary and replica via Docker Compose, with replication status, a failover or lag test, and a discussion of sharding by customer, availability versus consistency (CAP), and cloud deployment options.

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

# 4. Portfolio 2: load seed data
docker exec -i pg-bank psql -U postgres -d paybridge \
  < portfolio-2-query-optimisation/seed.sql
```

Then follow the README inside each portfolio folder. Do not commit passwords; use a placeholder or an ignored `.env` file.

## 6. Technical reflection
## Cover

ACID is used for the ledger to ensure that transaction data stays **Atomic, Consistent, Isolated, and Durable**, maintaining data integrity and reliability.

## Challenges

One of the challenges encountered was starting PostgreSQL using Docker.

### Terminal Output (Error)

```bash
    emmy@Emmys-MacBookPro advanced-database-portfolio % docker run --name pg-bank -e POSTGRES_PASSWORD=choose_a_password \
       -p 5432:5432 -d postgres:16

    failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory
```

Fix:
```bash
    emmy@Emmys-MacBookPro advanced-database-portfolio % open -a Docker

    emmy@Emmys-MacBookPro advanced-database-portfolio % docker info

    # After confirming Docker was running:

    emmy@Emmys-MacBookPro advanced-database-portfolio % docker run --name pg-bank -e POSTGRES_PASSWORD=choose_a_password \
    -p 5432:5432 -d postgres:16

    # Expected output: container ID
```

## 7. AI use declaration

- **Tool(s) used:** Claude (Anthropic).
- **Used for:** planning the work schedule, discussing the SQL vs NewSQL vs NoSQL design choices, and drafting starter versions of the schema, seed, query and index scripts and README text.
- **How I reviewed and verified:** I ran every script myself against PostgreSQL 16, checked the constraints with deliberate bad inserts, captured my own execution plans, modified the drafts to fit my design decisions, and wrote the analysis and reflection myself.

## 8. References

- PostgreSQL documentation: https://www.postgresql.org/docs/
- MongoDB documentation: https://www.mongodb.com/docs/
- Course materials and textbooks for MIT 8103.
- Docker documentation: https://docs.docker.com/