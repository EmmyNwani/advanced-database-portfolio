# Portfolio 2: Query Processing and Optimisation

**Case study:** PayBridge Microfinance Bank (see [Portfolio 1](../portfolio-1-database-design/README.md#1-case-study)). **Database:** PostgreSQL 16 in Docker, schema from Portfolio 1.

## 1. Objective

Show how the PostgreSQL planner executes realistic banking queries, measure them on a dataset large enough to matter, add indexes and rewrite a slow query, and explain what changed and what did not.

## 2. Files in this folder

| File | Purpose |
|---|---|
| [`seed.sql`](seed.sql) | Loads reproducible synthetic data (clears and reloads the data tables) |
| [`queries.sql`](queries.sql) | The six benchmark queries (Q1–Q6) |
| [`run_benchmarks.sh`](run_benchmarks.sh) | Runs each query under `EXPLAIN (ANALYZE, BUFFERS)` three times and saves the median plan |
| [`indexes.sql`](indexes.sql) | The indexes added after the baseline measurements |
| [`q5_rewrite.sql`](q5_rewrite.sql) | Q5 rewritten without a correlated subquery |
| [`plans/before/`](plans/before/) | Plans, timings ([`summary.txt`](plans/before/summary.txt)) and settings ([`environment.txt`](plans/before/environment.txt)) without secondary indexes |
| [`plans/after/`](plans/after/) | The same after running `indexes.sql` |
| [`plans/q5-rewrite/`](plans/q5-rewrite/) | Plans for the rewritten Q5, with and without indexes |
| [`outputs/`](outputs/) | Query results (`q1-result.txt` … `q6-result.txt`) and [`index-sizes.txt`](outputs/index-sizes.txt) |

## 3. Dataset

| Table | Rows |
|---|---|
| customers | 20,000 |
| accounts | 30,000 |
| transfers | 50,000 (44,866 completed, 3,617 failed, 1,517 reversed) |
| transactions | 190,800 |

The data is generated with `generate_series` and `random()` using a fixed seed (`setseed(0.42)`), so every run produces identical data. The ledger is internally consistent: each account's opening deposit is sized to cover its largest running deficit, `balance_after` is a running total computed with a window function, and `accounts.balance` equals the last `balance_after`. Completed transfers have exactly two ledger rows, reversed transfers four and failed transfers none (see Portfolio 1, screenshot 07).

## 4. Method

1. Load the schema (Portfolio 1), then `seed.sql`.
2. Run `run_benchmarks.sh before`. It runs `VACUUM ANALYZE`, then each query three times under `EXPLAIN (ANALYZE, BUFFERS)`, keeps the median, and saves the results.
3. Apply `indexes.sql`, which also ends with `VACUUM ANALYZE` and reports index sizes.
4. Run `run_benchmarks.sh after`.
5. Capture plans for `q5_rewrite.sql` with index scans disabled for the session (simulating no indexes) and with them enabled.

```bash
docker exec -i pg-bank psql -U postgres -d paybridge < portfolio-2-query-optimisation/seed.sql
./portfolio-2-query-optimisation/run_benchmarks.sh before
docker exec -i pg-bank psql -U postgres -d paybridge < portfolio-2-query-optimisation/indexes.sql
./portfolio-2-query-optimisation/run_benchmarks.sh after
```

Before indexing, the only indexes are those PostgreSQL creates automatically for primary keys and unique constraints. Foreign key columns are not indexed automatically.

Run order matters: the benchmarks must run on a freshly loaded schema and seed. `seed.sql` does not remove the Portfolio 2 indexes, and Portfolio 3 adds transfers and ledger rows, so rerunning the benchmarks after either would not reproduce the results below. To start again, reload `schema.sql` (which drops and recreates the tables) and then `seed.sql`.

## 5. Queries and results

Median of three runs (`Execution Time`), PostgreSQL 16.15 on an Apple Silicon Mac. Absolute times vary between machines; the before/after comparison is what matters.

| Query | What it does | Plan before | Before (ms) | Plan after | After (ms) |
|---|---|---|---|---|---|
| Q1 | October 2026 statement for account 23243 | Parallel Seq Scan on transactions + Sort | 7.953 | Index Scan on `idx_transactions_account_created`, no Sort | 0.069 |
| Q2 | All accounts of one customer, by email | Seq Scan on accounts + Hash Join | 3.549 | Index Scans only (email, `idx_accounts_customer`, PK) | 0.074 |
| Q3 | Transfers 25–31 Oct 2026 with both account numbers | Seq Scan on transfers + two Hash Joins | 15.451 | Index Scan Backward on `idx_transfers_initiated`; joins still Seq Scan + Hash | 11.581 |
| Q4 | Top 10 customers by completed amount sent, October 2026 | Seq Scans + Hash Joins + HashAggregate | 16.591 | Index Only Scan on the partial index (Heap Fetches: 0); joins unchanged | 13.443 |
| Q5 | Customers with 3+ failed transfers (correlated subquery) | Nested Loop: two Seq Scans repeated 20,000 times | 47,299.531 | Nested Loop: two index lookups repeated 20,000 times | 47.295 |
| Q6 | Top 5 balances per account type (`RANK()`) | Seq Scan + Sort + WindowAgg | 30.806 | Unchanged: index not used | 29.455 |

### Q5 rewrite

| Version | Time (ms) |
|---|---|
| Correlated subquery, no indexes | 47,299.531 |
| Correlated subquery, with indexes | 47.295 |
| Rewrite (`GROUP BY`), no indexes | 19.515 |
| Rewrite (`GROUP BY`), with indexes | 13.870 |

Both versions return the same 38 customers.

## 6. Indexes added

| Index | Definition | Intended for | Used in after-plan by | Size |
|---|---|---|---|---|
| `idx_transactions_account_created` | `transactions (account_id, created_at)` | Q1 | Q1 | 5,904 kB |
| `idx_accounts_customer` | `accounts (customer_id)` | Q2 | Q2, Q5 | 608 kB |
| `idx_transfers_initiated` | `transfers (initiated_at)` | Q3 | Q3 (scanned backward) | 1,112 kB |
| `idx_transfers_completed_date_sender` | `transfers (initiated_at, from_account) INCLUDE (amount) WHERE status = 'COMPLETED'` | Q4 | Q4 (index-only) | 2,144 kB |
| `idx_transfers_failed_sender` | `transfers (from_account) WHERE status = 'FAILED'` | Q5 | Q5 (index-only) | 96 kB |
| `idx_accounts_type_balance` | `accounts (type_code, balance DESC)` | Q6 | not used | 1,200 kB |

Total: about 11 MB. Table and index sizes after indexing:

| Table | Table data | All indexes (incl. keys and constraints) | Total |
|---|---|---|---|
| transactions | 16 MB | 17 MB | 33 MB |
| accounts | 5,456 kB | 5,008 kB | 10 MB |
| transfers | 4,104 kB | 4,464 kB | 8,600 kB |
| customers | 2,200 kB | 2,344 kB | 4,576 kB |

**Design choices**

- **Composite index, equality column first.** Q1 filters on one exact `account_id` and a range of `created_at`. With `account_id` first, the index jumps straight to that account's entries; within them, entries are already ordered by `created_at`, so October is one contiguous, pre-sorted slice. The reverse order would force a scan of every account's October entries.
- **Foreign key indexes.** PostgreSQL does not index foreign keys automatically. `idx_accounts_customer` supports the customer-to-accounts join in Q2 and, as it turned out, the per-customer lookup in Q5.
- **Partial indexes.** Q4 only reads completed transfers and Q5 only failed ones (7% of rows). Indexing just those rows keeps the indexes small (96 kB for failed transfers against 1,112 kB for the full date index) and means inserts of other statuses never touch them.
- **Covering index.** `INCLUDE (amount)` stores the summed column in the Q4 index, so the query can be answered without visiting the table (an index-only scan). `VACUUM` was run first so the visibility map was up to date; the plan reports `Heap Fetches: 0`.
- **Q6 index.** `(type_code, balance DESC)` matches the window's `PARTITION BY` and `ORDER BY`, so it could feed `RANK()` pre-sorted input. Whether the planner uses it was the open question.

## 7. Analysis

**Q1 (statement).** Before indexing, PostgreSQL read the whole `transactions` table with a parallel sequential scan, discarding 190,792 of 190,800 rows (2,068 buffer pages) and then sorting the 8 survivors. With the composite index it performs one index scan that touches 14 pages and returns the rows already in date order, so the Sort node disappears. Time fell from 7.953 ms to 0.069 ms (about 115×). The planner estimated 1 row against 8 actual; the error was harmless because either way the index was clearly the cheaper path.

**Q2 (customer balances).** The email lookup was already fast through the unique index created by the `UNIQUE` constraint, but finding the customer's accounts required a sequential scan of all 30,000 accounts. With `idx_accounts_customer` every step is an index lookup: 689 pages became 15 and time fell from 3.549 ms to 0.074 ms. This is the clearest example of why foreign key columns usually need an explicit index.

**Q3 (recent transfers).** The date filter selects 1,202 of 50,000 transfers (2.4%), and the plan switched from a sequential scan to a backward index scan on `idx_transfers_initiated`, which also serves the newest-first order. The gain was small (15.451 ms to 11.581 ms) because most of the work is elsewhere: both joins to `accounts` still build hash tables over all 30,000 accounts, and a Sort reappears because hashing does not preserve order. Indexing the filter only speeds up the part of the query it covers.

**Q4 (top senders).** The partial covering index produced an index-only scan with `Heap Fetches: 0`, so October's completed transfers were read without touching the table. Time fell only from 16.591 ms to 13.443 ms, because the query must still join to every customer, aggregate per customer and sort the totals before it can return the top 10. The `LIMIT` does not reduce that work: the top 10 is only known after every total has been computed.

**Q5 (failed transfers, correlated subquery).** This was the slowest query by far. The plan was a nested loop that ran the subquery once per customer (`loops=20000`), and each run scanned the whole of `transfers` and `accounts`: 23.9 million buffer page reads and 47,299 ms. The indexes did not change the algorithm, which still loops 20,000 times, but each loop became two index lookups (`idx_accounts_customer`, then the partial `idx_transfers_failed_sender`). Reads dropped to about 120,000 pages and time to 47.295 ms, roughly 1,000× faster.

Rewriting the query mattered more than indexing it. The `GROUP BY` version (`q5_rewrite.sql`) reads each table once, hash-joins them and groups the 3,617 failed transfers: 19.515 ms with index scans disabled and 13.870 ms with indexes, against 47.295 ms for the indexed correlated version. Both return the same 38 customers.

**Q6 (balance ranking).** No change: 30.806 ms before and 29.455 ms after, with an identical plan (sequential scan, in-memory sort of 2.4 MB, then `WindowAgg`) and the same 691 pages. `RANK()` has to number every one of the 30,000 accounts before the outer filter keeps the top five per type, so the query reads the whole table regardless. Reading it through the index would mean visiting the table in index order, page by page, which the planner costs higher than one sequential scan plus a fast in-memory sort. The index was therefore ignored, and correctly so: it adds 1,200 kB and write cost for no benefit to this query.

### Overall observations

- **Selective lookups gained the most.** Q1, Q2 and Q5 fetch a handful of rows by a key value, which is exactly what a B-tree is for: improvements of 48× to 1,000×.
- **Queries that must process most of a table gained little or nothing.** Q3 and Q4 are dominated by joins and aggregation over whole tables, and Q6 has to rank every account. An index only removes the work it covers.
- **Query design matters as much as indexing.** The Q5 rewrite, with no indexes at all, beat the indexed correlated subquery; the best result combined both.
- **Indexes have a cost.** The six new indexes take about 11 MB, and on `transactions` all indexes together (17 MB) are now larger than the table data (16 MB). Every deposit, withdrawal and transfer must update each index on the tables it writes to, so a ledger that writes constantly pays for each index on every write. The Q6 index is a candidate for removal: it costs storage and write time and no query uses it.

## 8. Limitations

- Synthetic, uniformly random data: real banking data is skewed (a few very active accounts), which could change plan choices.
- Opening deposits are sized so no balance falls below about ₦200,000, which is convenient but unrealistic.
- One machine, Docker on a laptop, warm cache; timings are indicative.

## 9. Reflection

