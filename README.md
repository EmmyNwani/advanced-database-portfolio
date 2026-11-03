# MIT 8103 Advanced Database Systems Portfolio

**Student:** Ugochukwu Emmanuel Nwani

**Student ID:** 301930571

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
├── portfolio-2-query-optimisation/
├── portfolio-3-transactions-concurrency/
├── portfolio-4-nosql/
├── portfolio-5-distributed-cloud/
└── README.md
```

Each folder has its own README explaining how that activity was implemented and tested.

## 4. Progress and evidence

| Portfolio | Topic | Where to look |
|---|---|---|
| 1 | Database design and modelling | `portfolio-1-database-design/` (`er-diagram/`, `schema.sql`, normalisation in README, `screenshots/`, `outputs/`) |

### Portfolio summaries

**Portfolio 1: Database design and modelling.** Relational design for the bank in 3NF with deliberate, documented denormalisation (`accounts.balance`, `transactions.balance_after`). Money is stored as `NUMERIC(15,2)`, business rules are enforced with `CHECK`, foreign key and unique constraints, and secondary indexes are intentionally left out for Portfolio 2.

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

- PostgreSQL documentation: https://www.postgresql.org/docs/
- MongoDB documentation: https://www.mongodb.com/docs/
- Course materials and textbooks for MIT 8103.
- Docker documentation: https://docs.docker.com/