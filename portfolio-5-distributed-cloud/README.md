# Portfolio 5: Distributed and Cloud Database Exercise

**Case study:** PayBridge Microfinance Bank (see [Portfolio 1](../portfolio-1-database-design/README.md#1-case-study)). **Databases:** PostgreSQL 16 primary and streaming replica, and a three-member MongoDB 7 replica set, all in Docker Compose.

## 1. Objective

Run the bank's databases on more than one node and test what that changes: how data is replicated, what a client can read from a replica, what happens when a node or the network fails, and how the bank could shard and deploy the system as it grows. Every scenario is run on the same data as Portfolios 1–4, using the Portfolio 3 `transfer_funds` function for writes.

## 2. Files in this folder

| File | Purpose |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | The cluster: `pg-primary`, `pg-replica`, `mongo1`–`mongo3` on a private network |
| [`primary-init.sh`](primary-init.sh) | Runs once on the primary: creates the `replicator` role and allows it to stream WAL |
| [`replica-entrypoint.sh`](replica-entrypoint.sh) | Clones the primary with `pg_basebackup` on first start, then runs as a hot standby |
| [`run_demos.sh`](run_demos.sh) | Builds the cluster from scratch, loads the data and runs demos 0–9 |
| [`sharding_analysis.sql`](sharding_analysis.sql) | Demo 9: how the data would spread across three shards under two shard keys |
| [`outputs/`](outputs/) | The output of every demo |
| [`screenshots/`](screenshots/) | The `run_demos.sh` run in the terminal |

## 3. How to run

From the repository root:

```bash
./portfolio-5-distributed-cloud/run_demos.sh
```

The script takes about a minute. It removes any previous cluster, starts all five containers, loads `schema.sql`, `seed.sql`, `transfer_funds.sql` and `audit_trigger.sql` into the primary only, and runs the demos in order. Each demo builds on the state the previous one left, so the cluster ends with the replica promoted and the old primary stopped. To remove it:

```bash
docker compose -f portfolio-5-distributed-cloud/docker-compose.yml down -v
```

The cluster is a separate Compose project (`paybridge-p5`) with no ports published to the host, so it does not touch the `pg-bank` and `mongo-bank` containers from Portfolios 1–4.

## 4. Architecture

```text
                  writes + reads                        reads only
  application ─────────────────►  pg-primary  ──WAL──►  pg-replica  ◄──── reports
                                  (read-write)  slot     (hot standby)
                                                replica1

  activity feed ──────────────►  mongo1 (PRIMARY, priority 2)
                                   │  oplog replication
                                   ├──► mongo2 (SECONDARY)
                                   └──► mongo3 (SECONDARY)
```

**PostgreSQL** uses physical streaming replication. The replica starts as a byte-for-byte copy made by `pg_basebackup`, then continuously receives and replays the primary's write-ahead log (WAL). A **replication slot** (`replica1`) makes the primary keep WAL until the replica has received it, so a replica that disconnects can catch up instead of needing a new copy. Replication is asynchronous by default: the primary confirms a commit without waiting for the replica.

**MongoDB** uses a replica set. Members elect one primary, and the secondaries copy its operation log (oplog). A write's **write concern** decides when it is acknowledged: `w: 1` after the primary has it, `w: "majority"` after most members have it.

## 5. Demonstrations

| # | Demo | What it shows | Evidence |
|---|---|---|---|
| 0 | Setup | All five containers running; 190,800 ledger rows loaded into the primary only appear on the replica with identical counts and total balance | [`outputs/00-setup.txt`](outputs/00-setup.txt) |
| 1 | Replication status | `pg_stat_replication` (streaming, async, LSNs and lag), the active slot, the replica's own view (`pg_is_in_recovery`, WAL receiver) | [`outputs/01-replication-status.txt`](outputs/01-replication-status.txt) |
| 2 | Write propagation | A transfer committed on the primary is already visible on the replica when read straight away; lag is under a millisecond | [`outputs/02-write-propagation.txt`](outputs/02-write-propagation.txt) |
| 3 | Read-only replica | A reporting query runs on the replica; a transfer, an `UPDATE` and a `CREATE TABLE` are refused | [`outputs/03-read-only-replica.txt`](outputs/03-read-only-replica.txt) |
| 4 | Stale read | With replay paused, a committed transfer shows on the primary but not on the replica; the replica reports how many bytes and seconds it is behind, then catches up | [`outputs/04-stale-read.txt`](outputs/04-stale-read.txt) |
| 5 | Synchronous replication | With the replica as a synchronous standby, a commit waits for it; with the replica stopped, a transfer waits (`SyncRep`) and stays invisible until the replica returns | [`outputs/05-synchronous-replication.txt`](outputs/05-synchronous-replication.txt) |
| 6 | Failover | The primary is stopped, the replica refuses writes until `pg_promote()`, then accepts transfers; transfer ids jump; all accounts still reconcile | [`outputs/06-failover.txt`](outputs/06-failover.txt) |
| 7 | Split brain | The old primary is restarted unfenced; both servers accept transfers and their balances and transfer lists diverge | [`outputs/07-split-brain.txt`](outputs/07-split-brain.txt) |
| 8 | MongoDB replica set | Majority writes with one member down succeed; with two down they time out, the primary steps down and refuses all writes, reads continue; a new primary is elected when members return | [`outputs/08-mongodb-replica-set.txt`](outputs/08-mongodb-replica-set.txt) |
| 9 | Sharding analysis | Data per shard for hash and range shard keys, the share of cross-shard transfers, and the effect of sharding by `account_id` | [`outputs/09-sharding-analysis.txt`](outputs/09-sharding-analysis.txt) |

## 6. Analysis: replication, consistency and availability

**Replication works, and is fast on one machine.** After loading, the replica held exactly the same 20,000 customers, 30,000 accounts, 50,000 transfers and 190,800 ledger rows, with the same total balance, although nothing was ever written to it directly. A single transfer was visible on the replica when read immediately, with replay lag under a millisecond. On one machine that is expected. Across data centres the lag would be at least the network round trip, and much more under heavy load.

**A replica is a read-scaling tool, not a second primary.** The replica ran the ranking report but refused every kind of write. This suits the bank: statements, reports and the Portfolio 2 analytical queries can move to replicas, leaving the primary for transfers.

**Asynchronous replication allows stale reads.** In demo 4 the client's transfer was committed and acknowledged, but a read from the replica still returned the old balance, and the replica reported exactly how far behind it was. For a customer who has just made a transfer, a stale balance looks like lost money. Reads that must reflect the customer's own writes ("read your writes") should go to the primary, or the application should wait until the replica has replayed the commit's LSN. Reports that tolerate a few seconds of delay can use the replica.

**Synchronous replication removes that gap but couples availability to the replica.** With `synchronous_standby_names = 'replica1'`, a commit returns only after the replica has the WAL on disk, so a confirmed transfer survives the loss of the primary. Demo 5 shows the cost. With the replica stopped, a transfer waited in `SyncRep` for as long as the replica was down, and it was not visible to other sessions. It completed only when the replica returned. In CAP terms, under a partition the synchronous configuration gives up availability (writes stop) to keep consistency. The asynchronous configuration stays available but can lose recently confirmed transfers on failover. A production setup usually runs two or more standbys with `ANY 1 (…)`, so one slow replica does not stop the bank.

**Failover changes who is primary but has gaps of its own.** After the primary stopped, the replica still refused writes until it was promoted. Failover is a decision, made by an operator or by a tool such as Patroni. Two effects were visible:
- **Transfer ids jumped.** PostgreSQL logs sequence values to WAL in batches of 32, so the promoted replica continued after the logged batch rather than from the last id used. Gaps are harmless here (Portfolio 3 already showed gaps from rollbacks), but ids must never be assumed to be consecutive.
- **Recovery point objective (RPO).** Because replication was asynchronous, any transfer the primary had confirmed but not yet sent would have been lost. Here the replica had caught up first, and every account still reconciled with its ledger.

**Split brain is the real danger.** When the old primary was restarted, nothing stopped it from acting as a primary. Two clients wrote to two servers, and account 9 ended with two different balances and two different sets of transfers. Neither server is wrong on its own; the bank simply has two ledgers. The fix is **fencing**: once the replica is promoted, the old primary must be prevented from accepting writes, for example by shutting it down or blocking it at the network. It must then be rebuilt as a replica of the new primary (with `pg_rewind` or a fresh `pg_basebackup`). Cluster managers such as Patroni use a consensus store and leader leases so that at most one node believes it is primary.

**MongoDB makes the same trade-off through write concerns and elections.**
- With one of three members down, `w: "majority"` writes still succeeded (two of three is a majority).
- With two down, the majority write timed out after three seconds. The primary then stepped down to secondary and refused every write, while reads continued.
- When the members returned, an election restored a primary.

The write whose majority acknowledgement failed was still applied on `mongo1` (the count read during the outage includes it). Such unacknowledged writes can be **rolled back** if another member is elected. That is why the activity data in Portfolio 4 tolerates `w: 1`, but anything with business consequences should use `w: "majority"`.

**Summary of the trade-offs (CAP / PACELC).** During a partition (P), each configuration chooses between availability (A) and consistency (C). With no partition (E, "else"), it chooses between latency (L) and consistency.

| Configuration | During a partition | With no partition |
|---|---|---|
| PostgreSQL async | Primary stays writable; failover can lose recent commits | Low commit latency; replica reads may be stale |
| PostgreSQL sync | Writes stop until a standby returns | Every commit waits a network round trip |
| MongoDB `w: "majority"` | Minority side refuses writes | Write latency includes a majority round trip |
| MongoDB `w: 1` | Faster acknowledgement; writes may be rolled back | Lowest latency |

The ledger needs the consistent choice: synchronous replication to at least one standby, with automatic, fenced failover. The activity log in MongoDB can take the faster, weaker options.

## 7. Analysis: sharding

Replication copies all the data to every node, which scales reads but not writes or storage. Sharding splits the data so that each node holds part of it. Demo 9 assigns every customer, with all their accounts and ledger rows, to one of three shards.

| Shard key | Customers per shard | Transfers sent per shard | October 2026 transfers per shard |
|---|---|---|---|
| Hash of `customer_id` | 6,628 / 6,672 / 6,700 | 16,489 / 16,591 / 16,920 | 1,947 / 2,032 / 2,001 |
| Range of join date | 8,013 / 6,099 / 5,888 | 20,026 / 15,240 / 14,734 | 1,901 / 1,596 / **2,483** |

**Hash on `customer_id` spreads the data evenly** (shards within 3% of each other), and current traffic is spread just as evenly. **Range on join date** looks natural but is skewed twice over: the oldest shard holds the most data, while the newest customers generate the most recent traffic, so the newest shard becomes a hot spot. It would also keep growing, because every new customer lands on it.

**`customer_id` is the right key, not `account_id`.** Keying by customer keeps a customer's accounts, transfers and history together, so the profile, the statement and the Portfolio 4 timeline are each served by one shard. Hashing `account_id` instead would split 5,344 of the 7,000 customers who have more than one account.

**The cost is cross-shard transfers.** With customers spread at random, 66.5% of transfers move money between two shards. That is two-thirds, as expected for three shards. The Portfolio 3 transfer is then no longer a local transaction: debiting on one node and crediting on another needs a **distributed transaction**, either two-phase commit (atomic, but blocking if the coordinator fails) or a **saga** (a debit, then a credit, with a compensating reversal if the credit fails). That compensating step is exactly the `REVERSED` status and `REVERSAL_IN/OUT` ledger types already in the Portfolio 1 schema. Distributed SQL databases such as CockroachDB and YugabyteDB handle this internally, running consensus-replicated, ACID transactions across shards at the cost of extra latency per write. For PostgreSQL, the Citus extension shards tables by a distribution column, and MongoDB shards a collection on a hashed key, such as `customer_id` for `activity_events`.

## 8. Cloud deployment

For production, PayBridge would run the same design on managed services rather than self-managed containers:

| Component | Deployment | Why |
|---|---|---|
| Ledger (PostgreSQL) | Managed PostgreSQL with a synchronous standby in a second availability zone and automatic failover (for example Amazon RDS Multi-AZ, Azure Database for PostgreSQL with zone-redundant HA, or Google Cloud SQL HA), plus one or more read replicas for reports | The provider handles failover and fencing, backups and point-in-time recovery, which demos 5–7 show are hard to get right by hand |
| Activity log (MongoDB) | Managed replica set across three zones (for example MongoDB Atlas), sharded on hashed `customer_id` when volume requires | One zone can fail without losing the majority; sharding follows Section 7 |
| Growth path | Citus, or a distributed SQL database such as CockroachDB, when one primary can no longer take the write load | Keeps ACID transfers while spreading writes |

The cloud also brings concerns that do not appear in a lab:
- **Data residency:** a Nigerian bank must check the Nigeria Data Protection Act 2023 and Central Bank of Nigeria rules on where customer data may be hosted, which affects the choice of region or provider.
- **Encryption** at rest and in transit, private networking, and least-privilege database roles.
- **Tested backups:** a regular restore drill, because replication copies mistakes such as a `DELETE` without a `WHERE` instantly.
- **Infrastructure as code,** so the environment can be rebuilt. `docker-compose.yml` is a small-scale version of this.

## 9. Limitations

- All nodes run on one laptop, so there is no real network latency or partition. Failures are simulated by stopping containers.
- Authentication inside the cluster is `trust` on a private Docker network with no published ports. Production would need passwords or certificates and TLS for replication.
- Failover and fencing are done by hand. No cluster manager (Patroni, `repmgr`) is used.
- Sharding is analysed, not deployed: no Citus or MongoDB sharded cluster was run.
- Timings and replication lag measured here are indicative only.

## 10. Reflection

