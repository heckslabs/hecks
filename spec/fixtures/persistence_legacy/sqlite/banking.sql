PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS "account" (id TEXT PRIMARY KEY, "customer" TEXT, "number" TEXT, "balance" TEXT, "kind" TEXT, "daily_limit" TEXT, "ledger" TEXT, "fees_cents" TEXT, "interest_cents" TEXT, "status" TEXT, "customer_status" TEXT);
INSERT INTO account VALUES('ACC-1','CUST-1','{"value":"ACC-1"}','{"cents":1250,"currency":"USD"}','{"name":"current"}','{"cents":500}','[{"sequence":{"value":1},"amount":{"cents":1000,"currency":"USD"},"narrative":{"text":"opening"},"direction":{"value":"credit"},"state":"posted"},{"sequence":{"value":2},"amount":{"cents":250,"currency":"USD"},"narrative":{"text":"top up"},"direction":{"value":"credit"},"state":"reversed"}]','{"cents":0,"currency":"USD"}','{"cents":0,"currency":"USD"}','open','active');
CREATE TABLE IF NOT EXISTS "account_entries" (
  sequence     INTEGER PRIMARY KEY AUTOINCREMENT,
  aggregate_id TEXT NOT NULL,
  operation    TEXT NOT NULL DEFAULT 'save',
  state        TEXT NOT NULL,
  mirrors      TEXT
);
INSERT INTO account_entries VALUES(1,'ACC-1','save','{"customer":"CUST-1","number":{"value":"ACC-1"},"balance":{"cents":1250,"currency":"USD"},"kind":{"name":"current"},"daily_limit":{"cents":500},"ledger":[{"sequence":{"value":1},"amount":{"cents":1000,"currency":"USD"},"narrative":{"text":"opening"},"direction":{"value":"credit"},"state":"posted"},{"sequence":{"value":2},"amount":{"cents":250,"currency":"USD"},"narrative":{"text":"top up"},"direction":{"value":"credit"},"state":"reversed"}],"fees_cents":{"cents":0,"currency":"USD"},"interest_cents":{"cents":0,"currency":"USD"},"status":"open","customer_status":"active"}',NULL);
CREATE TABLE events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  name         TEXT NOT NULL,
  aggregate    TEXT NOT NULL,
  aggregate_id TEXT NOT NULL,
  payload      TEXT,
  occurred_at  TEXT
);
CREATE TABLE hecks_saga_instances (
  domain               TEXT NOT NULL,
  process_manager      TEXT NOT NULL,
  correlation          TEXT NOT NULL,
  state                TEXT NOT NULL,
  memory               TEXT NOT NULL,
  completed_compensations  TEXT NOT NULL DEFAULT '[]',
  PRIMARY KEY (domain, process_manager, correlation)
);
CREATE TABLE hecks_outbox (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  delivery_id  TEXT NOT NULL UNIQUE,
  event_uid    TEXT NOT NULL,
  aggregate    TEXT NOT NULL,
  domain       TEXT NOT NULL,
  kind         TEXT NOT NULL,
  consumer     TEXT NOT NULL,
  event        TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending',
  attempts     INTEGER NOT NULL DEFAULT 0,
  error        TEXT,
  enqueued_at  TEXT NOT NULL,
  claimed_at   TEXT,
  settled_at   TEXT
);
CREATE TABLE IF NOT EXISTS "card_payment" (id TEXT PRIMARY KEY, "account" TEXT, "disputed_by" TEXT, "authorisation" TEXT, "amount" TEXT, "merchant" TEXT, "tags" TEXT, "status" TEXT, "account_status" TEXT, "account_customer_status" TEXT);
INSERT INTO card_payment VALUES('AUTH-1','ACC-1',NULL,'{"value":"AUTH-1"}','{"cents":300}','{"value":"Cafe"}','[{"value":"food"},{"value":"travel"}]','authorized','open',NULL);
CREATE TABLE IF NOT EXISTS "card_payment_entries" (
  sequence     INTEGER PRIMARY KEY AUTOINCREMENT,
  aggregate_id TEXT NOT NULL,
  operation    TEXT NOT NULL DEFAULT 'save',
  state        TEXT NOT NULL,
  mirrors      TEXT
);
INSERT INTO card_payment_entries VALUES(1,'AUTH-1','save','{"account":"ACC-1","disputed_by":null,"authorisation":{"value":"AUTH-1"},"amount":{"cents":300},"merchant":{"value":"Cafe"},"tags":[{"value":"food"},{"value":"travel"}],"status":"authorized","account_status":"open"}',NULL);
DELETE FROM sqlite_sequence;
INSERT INTO sqlite_sequence VALUES('account_entries',1);
INSERT INTO sqlite_sequence VALUES('card_payment_entries',1);
CREATE INDEX "idx_account_status" ON "account"("status");
CREATE INDEX "idx_account_number" ON "account"(json_extract("number", '$.value'));
CREATE INDEX "idx_account_balance" ON "account"(json_extract("balance", '$.cents'));
CREATE INDEX "idx_account_customer" ON "account"("customer");
CREATE INDEX idx_hecks_outbox_status ON hecks_outbox(aggregate, status);
CREATE INDEX "idx_card_payment_status" ON "card_payment"("status");
COMMIT;
