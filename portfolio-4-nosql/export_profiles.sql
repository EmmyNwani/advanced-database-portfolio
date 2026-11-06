-- MIT 8103 Portfolio 4: export one profile document per customer as MongoDB Extended JSON
-- The customer's accounts and KYC history are embedded, so the profile screen is a single read.
-- Balances are a snapshot (balance_as_of): PostgreSQL remains the source of truth for money.
-- KYC history is derived from customer_id exactly as in export_events.sql, so the two agree.
-- Read-only: nothing is written.

\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.edate(t timestamptz) RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$ SELECT jsonb_build_object('$date', to_char(t AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) $$;
CREATE FUNCTION pg_temp.dec(n numeric) RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$ SELECT jsonb_build_object('$numberDecimal', n::text) $$;

SELECT jsonb_strip_nulls(jsonb_build_object(
         '_id', c.customer_id,
         'full_name', c.full_name,
         'contact', jsonb_build_object('email', c.email, 'phone', c.phone),
         'joined_at', pg_temp.edate(c.created_at),
         'kyc', jsonb_build_object(
             'status', c.kyc_status,
             'history', CASE WHEN c.kyc_status = 'PENDING' THEN '[]'::jsonb ELSE jsonb_build_array(jsonb_build_object(
                 'status', c.kyc_status,
                 'at', pg_temp.edate(c.created_at + (1 + c.customer_id % 10) * interval '1 day'),
                 'document', (ARRAY['NIN','BVN','PASSPORT'])[1 + c.customer_id % 3],
                 'reviewed_by', 'officer-' || lpad((1 + c.customer_id % 12)::text, 2, '0'),
                 'rejection_reason', CASE WHEN c.kyc_status = 'REJECTED'
                     THEN (ARRAY['DOCUMENT_EXPIRED','NAME_MISMATCH','BLURRY_IMAGE'])[1 + c.customer_id % 3] END)) END),
         'accounts', a.accounts,
         -- Optional field: only some customers have set preferences
         'preferences', CASE WHEN c.customer_id % 4 = 0 THEN jsonb_build_object(
             'language', (ARRAY['en','yo','ig','ha'])[1 + c.customer_id % 16 / 4],
             'alerts', jsonb_build_object('sms', c.customer_id % 3 <> 0, 'email', true)) END,
         'balance_as_of', pg_temp.edate(now())
       ))::text
FROM customers c
JOIN (SELECT customer_id,
             jsonb_agg(jsonb_build_object(
                 'account_id', account_id,
                 'account_no', account_no,
                 'type', type_code,
                 'currency', currency,
                 'status', status,
                 'balance', pg_temp.dec(balance),
                 'opened_at', pg_temp.edate(opened_at)) ORDER BY account_id) AS accounts
      FROM accounts GROUP BY customer_id) a USING (customer_id)
ORDER BY c.customer_id;
