-- MIT 8103 Portfolio 2: Q5 rewritten without a correlated subquery
-- Same result as Q5 in queries.sql: customers with 3 or more failed outgoing transfers.
-- The original evaluates a subquery once per customer (20,000 times); this version
-- filters the failed transfers once, joins them to accounts and customers, and groups.
SELECT c.customer_id, c.full_name, count(*) AS failed_transfers
FROM transfers tr
JOIN accounts a  ON a.account_id  = tr.from_account
JOIN customers c ON c.customer_id = a.customer_id
WHERE tr.status = 'FAILED'
GROUP BY c.customer_id, c.full_name
HAVING count(*) >= 3
ORDER BY failed_transfers DESC, c.customer_id;
