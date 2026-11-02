-- MIT 8103 Portfolio 1: Database Design and Modelling
-- Case study: PayBridge Microfinance Bank (simulated digital bank)
-- Target: PostgreSQL 16 (run in Docker). Starter draft: review, test and adapt it.
-- Note: secondary indexes are deliberately omitted here so that Portfolio 2
-- can show query plans before and after indexing.

DROP TABLE IF EXISTS audit_log, transactions, transfers, accounts, account_types, customers CASCADE;

CREATE TABLE customers (
    customer_id   BIGSERIAL PRIMARY KEY,
    full_name     VARCHAR(120) NOT NULL,
    email         VARCHAR(150) NOT NULL UNIQUE,
    phone         VARCHAR(20)  NOT NULL UNIQUE,
    kyc_status    VARCHAR(10)  NOT NULL DEFAULT 'PENDING'
                  CHECK (kyc_status IN ('PENDING', 'VERIFIED', 'REJECTED')),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Product rules live here (not repeated per account) to satisfy 3NF.
CREATE TABLE account_types (
    type_code       VARCHAR(10) PRIMARY KEY,           -- e.g. SAVINGS, CURRENT
    description     VARCHAR(100) NOT NULL,
    min_balance     NUMERIC(15,2) NOT NULL DEFAULT 0 CHECK (min_balance >= 0),
    daily_limit     NUMERIC(15,2) NOT NULL CHECK (daily_limit > 0)
);

CREATE TABLE accounts (
    account_id    BIGSERIAL PRIMARY KEY,
    customer_id   BIGINT       NOT NULL REFERENCES customers(customer_id),
    account_no    CHAR(10)     NOT NULL UNIQUE,
    type_code     VARCHAR(10)  NOT NULL REFERENCES account_types(type_code),
    currency      CHAR(3)      NOT NULL DEFAULT 'NGN',
    balance       NUMERIC(15,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
    status        VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE'
                  CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    opened_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE transfers (
    transfer_id   BIGSERIAL PRIMARY KEY,
    from_account  BIGINT NOT NULL REFERENCES accounts(account_id),
    to_account    BIGINT NOT NULL REFERENCES accounts(account_id),
    amount        NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    status        VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING', 'COMPLETED', 'FAILED', 'REVERSED')),
    initiated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (from_account <> to_account)
);

CREATE TABLE transactions (
    txn_id         BIGSERIAL PRIMARY KEY,
    account_id     BIGINT NOT NULL REFERENCES accounts(account_id),
    transfer_id    BIGINT REFERENCES transfers(transfer_id),  -- NULL for deposits/withdrawals
    txn_type       VARCHAR(12) NOT NULL
                   CHECK (txn_type IN ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER_OUT', 'TRANSFER_IN',
                                       'REVERSAL_OUT', 'REVERSAL_IN')),
    amount         NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    balance_after  NUMERIC(15,2) NOT NULL CHECK (balance_after >= 0),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- deposits/withdrawals have no transfer; every transfer-related row must have one
    CONSTRAINT chk_txn_transfer_link CHECK (
        (txn_type IN ('DEPOSIT', 'WITHDRAWAL') AND transfer_id IS NULL)
        OR (txn_type NOT IN ('DEPOSIT', 'WITHDRAWAL') AND transfer_id IS NOT NULL)
    ),
    -- at most one row of each type per transfer (so at most 4 rows per transfer)
    CONSTRAINT uq_txn_transfer_type UNIQUE (transfer_id, txn_type)
);

CREATE TABLE audit_log (
    audit_id    BIGSERIAL PRIMARY KEY,
    table_name  VARCHAR(50) NOT NULL,
    record_id   BIGINT      NOT NULL,
    action      VARCHAR(10) NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    old_data    JSONB,
    new_data    JSONB,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Reference data so the schema can be tested immediately
INSERT INTO account_types (type_code, description, min_balance, daily_limit) VALUES
    ('SAVINGS', 'Savings account', 0, 500000),
    ('CURRENT', 'Current account', 0, 5000000);