-- Tables for the Fresh Mart store. Safe to run many times (IF NOT EXISTS).
-- The activity_log table is SHARED with the Python deli app (same columns there).
CREATE TABLE IF NOT EXISTS products (
  id     BIGSERIAL PRIMARY KEY,
  name   VARCHAR(100)  NOT NULL UNIQUE,
  emoji  VARCHAR(8)    NOT NULL DEFAULT '',
  price  NUMERIC(10,2) NOT NULL,
  stock  INTEGER       NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS orders (
  id         BIGSERIAL PRIMARY KEY,
  customer   VARCHAR(100)  NOT NULL,
  status     VARCHAR(20)   NOT NULL,          -- NEW or PAID
  total      NUMERIC(10,2) NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ   NOT NULL DEFAULT now(),
  paid_at    TIMESTAMPTZ,
  paid_by    VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS order_items (
  id         BIGSERIAL PRIMARY KEY,
  order_id   BIGINT        NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id BIGINT        NOT NULL REFERENCES products(id),
  quantity   INTEGER       NOT NULL,
  unit_price NUMERIC(10,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS activity_log (
  id          BIGSERIAL PRIMARY KEY,
  occurred_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
  service     VARCHAR(50)  NOT NULL,          -- java-store or python-deli
  actor       VARCHAR(100) NOT NULL,          -- username or 'anonymous'
  action      VARCHAR(100) NOT NULL,          -- LOGIN, PAGE_VIEW, API_CALL, ORDER_PLACED ...
  method      VARCHAR(10),
  path        VARCHAR(500),
  status      INTEGER,
  details     TEXT
);
CREATE INDEX IF NOT EXISTS idx_activity_log_occurred_at ON activity_log (occurred_at DESC);
