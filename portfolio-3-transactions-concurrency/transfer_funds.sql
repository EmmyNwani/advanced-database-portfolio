-- MIT 8103 Portfolio 3: atomic fund transfer for PayBridge Microfinance Bank
-- Target: PostgreSQL 16, after Portfolio 1 schema and Portfolio 2 seed data.
--
-- transfer_funds(from, to, amount) moves money between two accounts as one unit of work:
-- it writes the transfer, both balance changes and both ledger rows, or nothing at all.
-- Any failed guardrail raises an exception, which rolls back the whole transaction.

CREATE OR REPLACE FUNCTION transfer_funds(p_from BIGINT, p_to BIGINT, p_amount NUMERIC(15,2))
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_first       accounts%ROWTYPE;
    v_second      accounts%ROWTYPE;
    v_from        accounts%ROWTYPE;
    v_to          accounts%ROWTYPE;
    v_min_balance NUMERIC(15,2);
    v_daily_limit NUMERIC(15,2);
    v_sent_today  NUMERIC(15,2);
    v_transfer_id BIGINT;
BEGIN
    -- Guardrail 1: valid request
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive (got %)', p_amount;
    END IF;
    IF p_from = p_to THEN
        RAISE EXCEPTION 'Cannot transfer from account % to itself', p_from;
    END IF;

    -- Lock both accounts in ascending account_id order. Every transfer takes its locks
    -- in the same order, so two transfers in opposite directions cannot deadlock.
    SELECT * INTO v_first  FROM accounts WHERE account_id = LEAST(p_from, p_to)    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % does not exist', LEAST(p_from, p_to);
    END IF;
    SELECT * INTO v_second FROM accounts WHERE account_id = GREATEST(p_from, p_to) FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % does not exist', GREATEST(p_from, p_to);
    END IF;

    IF p_from < p_to THEN
        v_from := v_first;  v_to := v_second;
    ELSE
        v_from := v_second; v_to := v_first;
    END IF;

    -- Guardrail 2: both accounts active
    IF v_from.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Source account % is %', p_from, v_from.status;
    END IF;
    IF v_to.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Destination account % is %', p_to, v_to.status;
    END IF;

    -- Guardrail 3: same currency
    IF v_from.currency <> v_to.currency THEN
        RAISE EXCEPTION 'Currency mismatch: % to %', v_from.currency, v_to.currency;
    END IF;

    SELECT min_balance, daily_limit INTO v_min_balance, v_daily_limit
    FROM account_types WHERE type_code = v_from.type_code;

    -- Guardrail 4: sufficient funds (the balance cannot fall below the product's minimum)
    IF v_from.balance - p_amount < v_min_balance THEN
        RAISE EXCEPTION 'Insufficient funds in account %: balance %, transfer %',
            p_from, v_from.balance, p_amount;
    END IF;

    -- Guardrail 5: daily outgoing limit for the product
    SELECT COALESCE(SUM(amount), 0) INTO v_sent_today
    FROM transactions
    WHERE account_id = p_from
      AND txn_type   = 'TRANSFER_OUT'
      AND created_at >= date_trunc('day', now());

    IF v_sent_today + p_amount > v_daily_limit THEN
        RAISE EXCEPTION 'Daily limit exceeded for account %: sent today %, limit %, requested %',
            p_from, v_sent_today, v_daily_limit, p_amount;
    END IF;

    -- All checks passed: write the transfer, both balances and both ledger rows
    INSERT INTO transfers (from_account, to_account, amount, status)
    VALUES (p_from, p_to, p_amount, 'COMPLETED')
    RETURNING transfer_id INTO v_transfer_id;

    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_from;
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_to;

    INSERT INTO transactions (account_id, transfer_id, txn_type, amount, balance_after)
    VALUES (p_from, v_transfer_id, 'TRANSFER_OUT', p_amount, v_from.balance - p_amount),
           (p_to,   v_transfer_id, 'TRANSFER_IN',  p_amount, v_to.balance   + p_amount);

    RETURN v_transfer_id;
END;
$$;
