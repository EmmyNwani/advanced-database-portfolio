-- MIT 8103 Portfolio 4: export customer activity events from PostgreSQL as MongoDB Extended JSON
-- One JSON document per line, piped into mongoimport (see load.sh). Read-only: nothing is written.
--
-- Five event types share one collection but have different shapes:
--   TRANSFER        from the real Portfolio 2 transfers (ids 1-50,000), with the sender as customer
--   LOGIN           successful logins, generated
--   LOGIN_FAILED    failed logins with a reason, generated, plus a burst pattern for 25 customers
--   KYC_UPDATE      KYC decisions for VERIFIED and REJECTED customers, derived from customer_id
--   DEVICE_CHANGE   a customer registering a new phone, generated
-- The channel decides the extra fields: MOBILE has a device, WEB a browser, USSD neither.
-- Deterministic: setseed() fixes random(); KYC events are computed from customer_id.

\set ON_ERROR_STOP on
SET max_parallel_workers_per_gather = 0;
SET TIME ZONE 'UTC';
SELECT setseed(0.84) AS s \gset

-- Extended JSON helpers: dates as BSON dates, money as Decimal128
CREATE FUNCTION pg_temp.edate(t timestamptz) RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$ SELECT jsonb_build_object('$date', to_char(t AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) $$;
CREATE FUNCTION pg_temp.dec(n numeric) RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$ SELECT jsonb_build_object('$numberDecimal', n::text) $$;
CREATE FUNCTION pg_temp.pick(arr text[], r double precision) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT arr[1 + floor(r * array_length(arr, 1))::int] $$;

-- Channel-specific fields for one event
CREATE FUNCTION pg_temp.channel_fields(channel text, r1 double precision, r2 double precision, r3 double precision,
                                       cust bigint) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
SELECT CASE channel
  WHEN 'MOBILE' THEN jsonb_build_object('device', jsonb_build_object(
        'os', CASE WHEN r1 < 0.7 THEN 'Android' ELSE 'iOS' END,
        'model', CASE WHEN r1 < 0.7 THEN pg_temp.pick(ARRAY['Tecno Spark 20','Infinix Hot 40','Samsung A15','itel P55'], r2)
                      ELSE pg_temp.pick(ARRAY['iPhone 12','iPhone 13','iPhone 15'], r2) END,
        'app_version', '4.' || floor(r3 * 3)::int || '.' || floor(r2 * 10)::int))
  WHEN 'WEB' THEN jsonb_build_object('browser', jsonb_build_object(
        'name', pg_temp.pick(ARRAY['Chrome','Safari','Firefox','Edge'], r2),
        'os', pg_temp.pick(ARRAY['Windows','macOS','Android','Linux'], r3)))
  ELSE jsonb_build_object('ussd', jsonb_build_object(
        'short_code', '*737#',
        'phone', '080' || lpad(cust::text, 8, '0')))
END $$;

CREATE FUNCTION pg_temp.location(r double precision) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
SELECT jsonb_build_object(
         'city',  (ARRAY['Lagos','Abuja','Port Harcourt','Kano','Ibadan','Enugu','Benin City','Kaduna'])[k],
         'state', (ARRAY['Lagos','FCT','Rivers','Kano','Oyo','Enugu','Edo','Kaduna'])[k])
FROM (SELECT 1 + floor(r * 8)::int AS k) x
$$;

CREATE FUNCTION pg_temp.channel(r double precision) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN r < 0.60 THEN 'MOBILE' WHEN r < 0.85 THEN 'WEB' ELSE 'USSD' END $$;

-- 1. TRANSFER events (50,000), from the seeded transfers only, so Portfolio 3 runs do not change the export
CREATE TEMP TABLE ev_transfer AS
SELECT t.transfer_id, a.customer_id, t.initiated_at AS ts, t.from_account, t.to_account, t.amount, t.status,
       pg_temp.channel(random()) AS channel, random() AS r1, random() AS r2, random() AS r3, random() AS r4
FROM transfers t JOIN accounts a ON a.account_id = t.from_account
WHERE t.transfer_id <= 50000
ORDER BY t.transfer_id;

-- 2. LOGIN and LOGIN_FAILED events (100,000), each after the customer joined; 8% fail
CREATE TEMP TABLE ev_login AS
SELECT g.i, c.customer_id,
       c.created_at + g.rt * (timestamptz '2026-11-01' - c.created_at) AS ts,
       g.rf < 0.08 AS failed, pg_temp.channel(g.rc) AS channel, g.r1, g.r2, g.r3, g.r4
FROM (SELECT i, 1 + floor(random() * 20000)::bigint AS cid, random() AS rt, random() AS rf, random() AS rc,
             random() AS r1, random() AS r2, random() AS r3, random() AS r4
      FROM generate_series(1, 100000) AS i) g
JOIN customers c ON c.customer_id = g.cid
ORDER BY g.i;

-- 3. DEVICE_CHANGE events (3,000)
CREATE TEMP TABLE ev_device AS
SELECT g.i, c.customer_id,
       c.created_at + g.rt * (timestamptz '2026-11-01' - c.created_at) AS ts,
       g.r1, g.r2, g.r3, g.r4
FROM (SELECT i, 1 + floor(random() * 20000)::bigint AS cid, random() AS rt,
             random() AS r1, random() AS r2, random() AS r3, random() AS r4
      FROM generate_series(1, 3000) AS i) g
JOIN customers c ON c.customer_id = g.cid
ORDER BY g.i;

-- Output: one document per line, with a deterministic _id
SELECT jsonb_strip_nulls(doc)::text
FROM (
  SELECT 1 AS grp, transfer_id AS n, jsonb_build_object(
           '_id', 'TRF-' || transfer_id,
           'type', 'TRANSFER',
           'customer_id', customer_id,
           'ts', pg_temp.edate(ts),
           'channel', channel,
           'location', pg_temp.location(r4),
           'transfer', jsonb_build_object(
               'transfer_id', transfer_id, 'from_account', from_account, 'to_account', to_account,
               'amount', pg_temp.dec(amount), 'currency', 'NGN', 'status', status),
           'failure_reason', CASE WHEN status = 'FAILED'
                                  THEN pg_temp.pick(ARRAY['INSUFFICIENT_FUNDS','LIMIT_EXCEEDED','NETWORK_TIMEOUT'], r2) END,
           'reversal', CASE WHEN status = 'REVERSED' THEN jsonb_build_object(
                                  'reason', pg_temp.pick(ARRAY['BENEFICIARY_BANK_DOWN','DISPUTED','DUPLICATE'], r3),
                                  'reversed_at', pg_temp.edate(ts + interval '2 hours')) END
         ) || pg_temp.channel_fields(channel, r1, r2, r3, customer_id) AS doc
  FROM ev_transfer

  UNION ALL
  SELECT 2, i, jsonb_build_object(
           '_id', 'LGN-' || i,
           'type', CASE WHEN failed THEN 'LOGIN_FAILED' ELSE 'LOGIN' END,
           'customer_id', customer_id,
           'ts', pg_temp.edate(ts),
           'channel', channel,
           'location', pg_temp.location(r4),
           'ip', CASE WHEN channel <> 'USSD'
                      THEN '102.89.' || floor(r1 * 256)::int || '.' || floor(r2 * 256)::int END,
           'failure_reason', CASE WHEN failed
                                  THEN pg_temp.pick(ARRAY['WRONG_PIN','WRONG_PASSWORD','OTP_EXPIRED','ACCOUNT_LOCKED'], r3) END,
           'mfa', CASE WHEN channel = 'MOBILE' AND NOT failed THEN
                         CASE WHEN r3 < 0.5 THEN 'BIOMETRIC' ELSE 'PIN' END END
         ) || pg_temp.channel_fields(channel, r1, r2, r3, customer_id)
  FROM ev_login

  UNION ALL
  -- Burst pattern: customers 800, 1600, ..., 20000 get 8 failed logins within about 30 minutes
  -- from one unfamiliar IP on 2026-10-20, followed by a device change: a typical account-takeover signal
  SELECT 3, b.customer_id * 100 + k, jsonb_build_object(
           '_id', 'BRS-' || b.customer_id || '-' || k,
           'type', 'LOGIN_FAILED',
           'customer_id', b.customer_id,
           'ts', pg_temp.edate(timestamptz '2026-10-20 02:00' + (b.customer_id / 800) * interval '1 hour'
                               + k * interval '4 minutes'),
           'channel', 'WEB',
           'location', jsonb_build_object('city', 'Unknown', 'state', 'Unknown'),
           'ip', '185.220.101.' || (b.customer_id / 800),
           'failure_reason', 'WRONG_PASSWORD',
           'browser', jsonb_build_object('name', 'Chrome', 'os', 'Linux'))
  FROM (SELECT customer_id FROM customers WHERE customer_id % 800 = 0) b
  CROSS JOIN generate_series(1, 8) AS k

  UNION ALL
  SELECT 4, customer_id, jsonb_build_object(
           '_id', 'KYC-' || customer_id,
           'type', 'KYC_UPDATE',
           'customer_id', customer_id,
           'ts', pg_temp.edate(created_at + (1 + customer_id % 10) * interval '1 day'),
           'channel', 'BRANCH',
           'kyc', jsonb_build_object(
               'from_status', 'PENDING',
               'to_status', kyc_status,
               'document', jsonb_build_object(
                   'type', (ARRAY['NIN','BVN','PASSPORT'])[1 + customer_id % 3],
                   'last4', lpad(((customer_id * 7919) % 10000)::text, 4, '0')),
               'reviewed_by', 'officer-' || lpad((1 + customer_id % 12)::text, 2, '0'),
               'rejection_reason', CASE WHEN kyc_status = 'REJECTED'
                   THEN (ARRAY['DOCUMENT_EXPIRED','NAME_MISMATCH','BLURRY_IMAGE'])[1 + customer_id % 3] END))
  FROM customers
  WHERE kyc_status IN ('VERIFIED', 'REJECTED')

  UNION ALL
  SELECT 5, i, jsonb_build_object(
           '_id', 'DEV-' || i,
           'type', 'DEVICE_CHANGE',
           'customer_id', customer_id,
           'ts', pg_temp.edate(ts),
           'channel', 'MOBILE',
           'location', pg_temp.location(r4),
           'old_device', pg_temp.channel_fields('MOBILE', r1, r2, r3, customer_id)->'device',
           'new_device', pg_temp.channel_fields('MOBILE', r2, r3, r1, customer_id)->'device',
           'verified_by', CASE WHEN r4 < 0.9 THEN 'OTP' ELSE 'BRANCH_VISIT' END)
  FROM ev_device

  UNION ALL
  SELECT 6, customer_id, jsonb_build_object(
           '_id', 'DEV-BRS-' || customer_id,
           'type', 'DEVICE_CHANGE',
           'customer_id', customer_id,
           'ts', pg_temp.edate(timestamptz '2026-10-20 02:40' + (customer_id / 800) * interval '1 hour'),
           'channel', 'MOBILE',
           'location', jsonb_build_object('city', 'Unknown', 'state', 'Unknown'),
           'new_device', jsonb_build_object('os', 'Android', 'model', 'Unknown', 'app_version', '4.2.1'),
           'verified_by', 'OTP')
  FROM customers WHERE customer_id % 800 = 0
) e
ORDER BY grp, n;
