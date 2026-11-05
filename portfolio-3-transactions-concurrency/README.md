# Portfolio 3: Transactions and Concurrency

**Case study:** PayBridge Microfinance Bank (see [Portfolio 1](../portfolio-1-database-design/README.md#1-case-study)). **Database:** PostgreSQL 16 in Docker, with the Portfolio 1 schema and Portfolio 2 seed data.

## 1. Objective

Show how the bank's money movements stay correct when things fail and when many users act at once: a transfer that is all-or-nothing, guardrails that reject invalid transfers, explicit commit and rollback, a reproduced concurrency anomaly with the mechanism that prevents it, and the effect of isolation levels.

## 2. Files in this folder

| File | Purpose |
|---|---|
| [`transfer_funds.sql`](transfer_funds.sql) | `transfer_funds(from, to, amount)`: the atomic transfer with its guardrails |
| [`audit_trigger.sql`](audit_trigger.sql) | Trigger that writes every balance change to `audit_log` |
| [`01_commit.sql`](01_commit.sql) | Demo 1: a successful transfer and its effects |
| [`02_rollback.sql`](02_rollback.sql) | Demo 2: guardrail failures, explicit `ROLLBACK`, an error rolling back earlier work, `SAVEPOINT` |
| [`concurrency_demos.sh`](concurrency_demos.sh) | Demos 3–8: two concurrent sessions for lost update, deadlock and isolation |
| [`outputs/`](outputs/) | The output of every demo |

## 3. How to run

From the repository root, after Portfolios 1 and 2 are loaded:

```bash
P3=portfolio-3-transactions-concurrency
mkdir -p $P3/outputs
docker exec -i pg-bank psql -U postgres -d paybridge < $P3/transfer_funds.sql
docker exec -i pg-bank psql -U postgres -d paybridge < $P3/audit_trigger.sql
docker exec -i pg-bank sh -c 'stdbuf -oL -eL psql -U postgres -d paybridge -X 2>&1' < $P3/01_commit.sql   > $P3/outputs/01-commit.txt
docker exec -i pg-bank sh -c 'stdbuf -oL -eL psql -U postgres -d paybridge -X 2>&1' < $P3/02_rollback.sql > $P3/outputs/02-rollback.txt
./$P3/concurrency_demos.sh
```

`stdbuf` keeps error messages next to the statement that caused them. The demos use accounts 1 and 3 (savings), 6 and 9 (current), 28 (frozen) and 38 (closed).

Run the steps once, in this order, on freshly loaded Portfolio 1 and 2 data: each demo starts from the balances the previous one left. The outputs in this folder come from a single such run. To repeat it, reload `schema.sql`, `seed.sql` and `indexes.sql` first. `concurrency_demos.sh` checks that accounts 1, 3, 6 and 9 reconcile with the ledger before it starts, and stops if they do not.

## 4. The atomic transfer and ACID

`transfer_funds` does all of its work inside the caller's transaction: it inserts the transfer, debits one account, credits the other and writes both ledger rows. Every guardrail runs before any write, and a failed guardrail raises an exception.

| Property | How the design provides it |
|---|---|
| **Atomicity** | The function's five writes belong to one transaction. Any exception, from a guardrail or from a constraint, rolls back all of them, so a transfer can never debit without crediting. |
| **Consistency** | Guardrails enforce business rules (positive amount, different accounts, both `ACTIVE`, same currency, balance stays at or above the product minimum, product daily limit), and the Portfolio 1 `CHECK` and foreign key constraints remain as a second line of defence. Balance and ledger are updated together, so the stored balance always reconciles with the ledger. |
| **Isolation** | Both account rows are locked with `SELECT … FOR UPDATE` before any check, so no other transaction can change them between the check and the write. Locks are always taken in ascending `account_id` order, which prevents deadlocks between opposite transfers (demo 6). |
| **Durability** | Once `COMMIT` returns, PostgreSQL has written the change to its write-ahead log, so it survives a crash. |

Locking before checking matters: if the balance were read without a lock, two transfers could both pass the funds check and together overdraw the account. With the lock, the second transfer waits and then checks the updated balance. For the same reason, the daily-limit total cannot be exceeded by two simultaneous transfers from the same account.

## 5. Demonstrations

| # | Demo | What it shows | Evidence |
|---|---|---|---|
| 1 | Commit | A transfer of 25,000 from account 1 to account 3 moves both balances, writes one transfer row, two ledger rows and two audit entries, and the balances still reconcile with the ledger | [`outputs/01-commit.txt`](outputs/01-commit.txt) |
| 2 | Rollback | Seven guardrails each reject a bad transfer with no rows written; an explicit `ROLLBACK` undoes a successful transfer; an error later in a transaction undoes an earlier success; a `SAVEPOINT` keeps the good transfer and discards the failed one | [`outputs/02-rollback.txt`](outputs/02-rollback.txt) |
| 3 | Lost update | Two deposits (1,000 and 500) both read the same balance and write their own result; the final balance includes only the 500 | [`outputs/03-lost-update.txt`](outputs/03-lost-update.txt) |
| 4 | Lost update prevented | The same deposits with `SELECT … FOR UPDATE`: the second session waits for the first to commit and both deposits survive | [`outputs/04-lost-update-prevented.txt`](outputs/04-lost-update-prevented.txt) |
| 5 | Deadlock | Session A locks account 1 then 3, session B locks 3 then 1; PostgreSQL detects the cycle and aborts one of them | [`outputs/05-deadlock.txt`](outputs/05-deadlock.txt) |
| 6 | Deadlock prevented | Both sessions lock the two accounts in `account_id` order; B waits for A instead of deadlocking, and both complete | [`outputs/06-deadlock-prevented.txt`](outputs/06-deadlock-prevented.txt) |
| 7 | `READ COMMITTED` | Two reads of the same balance inside one transaction return different values after another session commits a transfer (non-repeatable read) | [`outputs/07-read-committed.txt`](outputs/07-read-committed.txt) |
| 8 | `REPEATABLE READ` | The same scenario: both reads return the same value because the transaction works from one snapshot | [`outputs/08-repeatable-read.txt`](outputs/08-repeatable-read.txt) |

Demos 3–6 deliberately update balances directly, without ledger rows, so the script restores the original balances afterwards and finishes with a reconciliation check (expected: 0 mismatching accounts).

Transfer ids in the recorded run: 50001 is the committed transfer in demo 1; 50002 and 50003 were rolled back in parts B and C of demo 2, so they never appear in the table; 50004 is the transfer kept by the savepoint in part D; 50005 and 50006 are session B's transfers in demos 7 and 8. The run ends with 50,004 transfers, and every account reconciles with its ledger.

## 6. Analysis

**Commit and rollback.** Demo 1 shows atomicity in the success case: every part of the transfer appears together, and the audit trigger's entries are part of the same transaction. Demo 2 shows it in the failure cases. Each guardrail failure leaves the transfer and ledger row counts unchanged. Part B shows that changes visible inside an open transaction disappear on `ROLLBACK`. Part C is the strongest case: the first transfer succeeded, but a later statement failed, so PostgreSQL marked the whole transaction as aborted and turned `COMMIT` into `ROLLBACK`. Part D shows the controlled alternative: a `SAVEPOINT` lets the application discard only the failed step. One visible side effect: transfer ids consumed by rolled-back transfers are not reused, because sequences are deliberately not transactional, so gaps in `transfer_id` are normal.

**Lost update.** Under PostgreSQL's default `READ COMMITTED` level, both sessions read the same starting balance. Session A wrote its result and committed; Session B then wrote a value computed from its stale read, overwriting A's deposit. Nothing raised an error, and the audit log shows both writes, which is what makes this anomaly dangerous: the data is wrong but no one is told. With `SELECT … FOR UPDATE`, B's read blocks until A commits (the output shows B requesting the row about a second before receiving it) and then returns the updated balance. Two other fixes would also work: an atomic `UPDATE … SET balance = balance + 500`, which never reads a stale value, or `REPEATABLE READ`, under which B's update would fail with a serialization error and could be retried. `transfer_funds` uses the row lock.

**Deadlock.** Each session held one account and waited for the other's, a cycle that neither could break. After `deadlock_timeout` (1 second by default) PostgreSQL detected the cycle, aborted one transaction with `deadlock detected`, and let the other finish. The aborted transfer has to be retried by the application. Demo 6 removes the cause instead: when every transaction locks accounts in the same global order, a cycle cannot form, and the second session simply waits. `transfer_funds` applies this rule by locking `LEAST(from, to)` before `GREATEST(from, to)`.

**Isolation levels.** Under `READ COMMITTED` each statement sees data committed before that statement began, so a second read within the same transaction can return a different value. That is acceptable for a single transfer, which locks what it changes, but not for something like an end-of-day report that reads many accounts and must add up. Under `REPEATABLE READ` the transaction sees one snapshot taken at its first query, so both reads agree; the new balance becomes visible only after the transaction ends. The cost is that a `REPEATABLE READ` transaction that tries to update a row changed by someone else gets a serialization error and must retry.

### Overall observations

- Correctness in a bank depends on the database enforcing rules inside transactions, not on application code remembering to check them.
- The default isolation level does not prevent lost updates on its own; the code has to lock or update atomically.
- Locking adds waiting: every transfer touching a busy account queues behind the previous one. For a ledger that is the right trade-off, but it limits throughput on very active accounts.

## 7. Limitations

- The daily limit uses the database server's date (UTC) and counts only completed outgoing transfers.
- The concurrency demos control timing with `pg_sleep`, which makes the interleaving reproducible but is simpler than real traffic.
- Reversals are modelled in the schema but not implemented as a function here.
- The restore in demos 3–6 is only safe if the script runs to the end. During development an interrupted run left account 9 1,000.00 above its ledger total; the next run restored to that wrong starting balance, and the full reconciliation query caught the difference. This is why the script now checks reconciliation before it starts.

## 8. Reflection

