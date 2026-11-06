-- MIT 8103 Portfolio 5: what sharding the bank's data across 3 nodes would look like
-- Read-only analysis on the seeded data. Each customer is assigned to a shard, and all of a customer's
-- accounts and ledger rows live on that shard. Two shard keys are compared.

\pset footer off
SET TIME ZONE 'UTC';

CREATE TEMP VIEW owner_shard AS
SELECT a.account_id, c.customer_id,
       (hashint8(c.customer_id) & 2147483647) % 3 AS hash_shard,     -- hash of customer_id
       CASE WHEN c.created_at < '2025-07-01' THEN 0                    -- range of join date
            WHEN c.created_at < '2026-01-01' THEN 1 ELSE 2 END AS range_shard
FROM accounts a JOIN customers c USING (customer_id);

\echo '=== 1. Hash sharding on customer_id: data per shard'
SELECT o.hash_shard AS shard,
       count(DISTINCT o.customer_id) AS customers,
       count(*) AS accounts,
       (SELECT count(*) FROM transfers t JOIN owner_shard s ON s.account_id = t.from_account
        WHERE s.hash_shard = o.hash_shard AND t.transfer_id <= 50000) AS transfers_sent,
       (SELECT count(*) FROM transfers t JOIN owner_shard s ON s.account_id = t.from_account
        WHERE s.hash_shard = o.hash_shard AND t.transfer_id <= 50000
          AND t.initiated_at >= '2026-10-01') AS sent_in_oct_2026
FROM owner_shard o GROUP BY o.hash_shard ORDER BY shard;

\echo '=== 2. Range sharding on join date: data per shard'
SELECT o.range_shard AS shard,
       CASE o.range_shard WHEN 0 THEN 'before Jul 2025' WHEN 1 THEN 'Jul-Dec 2025' ELSE 'from Jan 2026' END AS joined,
       count(DISTINCT o.customer_id) AS customers,
       count(*) AS accounts,
       (SELECT count(*) FROM transfers t JOIN owner_shard s ON s.account_id = t.from_account
        WHERE s.range_shard = o.range_shard AND t.transfer_id <= 50000) AS transfers_sent,
       (SELECT count(*) FROM transfers t JOIN owner_shard s ON s.account_id = t.from_account
        WHERE s.range_shard = o.range_shard AND t.transfer_id <= 50000
          AND t.initiated_at >= '2026-10-01') AS sent_in_oct_2026
FROM owner_shard o GROUP BY o.range_shard ORDER BY shard;

\echo '=== 3. Transfers whose two accounts are on different shards (hash on customer_id)'
SELECT count(*) AS transfers,
       count(*) FILTER (WHERE f.hash_shard = t2.hash_shard) AS same_shard,
       count(*) FILTER (WHERE f.hash_shard <> t2.hash_shard) AS cross_shard,
       round(100.0 * count(*) FILTER (WHERE f.hash_shard <> t2.hash_shard) / count(*), 1) AS cross_shard_pct
FROM transfers t
JOIN owner_shard f  ON f.account_id = t.from_account
JOIN owner_shard t2 ON t2.account_id = t.to_account
WHERE t.transfer_id <= 50000;

\echo '=== 4. Customers whose accounts would be split if the shard key were account_id instead'
SELECT count(*) AS customers_with_several_accounts,
       count(*) FILTER (WHERE shards > 1) AS split_across_shards
FROM (SELECT customer_id, count(DISTINCT (hashint8(account_id) & 2147483647) % 3) AS shards
      FROM accounts GROUP BY customer_id HAVING count(*) > 1) x;
