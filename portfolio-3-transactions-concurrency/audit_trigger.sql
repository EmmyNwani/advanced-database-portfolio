-- MIT 8103 Portfolio 3: audit trail for balance changes
-- Every change to accounts.balance writes the old and new row to audit_log,
-- inside the same transaction: if the change rolls back, so does its audit entry.

CREATE OR REPLACE FUNCTION audit_account_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_data, new_data)
    VALUES ('accounts', NEW.account_id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_account_balance ON accounts;

CREATE TRIGGER trg_audit_account_balance
AFTER UPDATE OF balance ON accounts
FOR EACH ROW
WHEN (OLD.balance IS DISTINCT FROM NEW.balance)
EXECUTE FUNCTION audit_account_balance();
