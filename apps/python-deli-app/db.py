"""
The notebook (database) for the Python deli.

Two flavours, chosen by DATABASE_URL:
  postgresql://...   the real store (shared with the Java app: same activity_log table)
  sqlite:///file.db  for local runs and tests (no Postgres needed)

Both use the same SQL; only "%s" vs "?" placeholders and the id column differ.
"""
import sqlite3
from datetime import datetime, timezone

from flask import current_app, g


def _is_sqlite():
    return current_app.config["DATABASE_URL"].startswith("sqlite:")


def get_conn():
    """One connection per request, stored on Flask's `g`."""
    if "db_conn" not in g:
        url = current_app.config["DATABASE_URL"]
        if url.startswith("sqlite:"):
            path = url[len("sqlite:///"):] or ":memory:"
            sqlite3.register_adapter(datetime, lambda d: d.isoformat())
            sqlite3.register_converter("TIMESTAMP", lambda b: datetime.fromisoformat(b.decode()))
            conn = sqlite3.connect(path, detect_types=sqlite3.PARSE_DECLTYPES)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA foreign_keys = ON")
        else:
            import psycopg
            from psycopg.rows import dict_row

            conn = psycopg.connect(url, row_factory=dict_row)
        g.db_conn = conn
    return g.db_conn


def close_conn(_exc=None):
    conn = g.pop("db_conn", None)
    if conn is not None:
        conn.close()


def _sql(query):
    """Postgres uses %s placeholders, sqlite uses ?."""
    return query.replace("%s", "?") if _is_sqlite() else query


def execute(query, params=(), fetch=None):
    conn = get_conn()
    cur = conn.cursor()
    cur.execute(_sql(query), params)
    rows = None
    if fetch == "one":
        rows = cur.fetchone()
    elif fetch == "all":
        rows = cur.fetchall()
    conn.commit()
    return rows


def insert_returning_id(query, params=()):
    """INSERT ... and give back the new id (works for both flavours)."""
    conn = get_conn()
    cur = conn.cursor()
    if _is_sqlite():
        cur.execute(_sql(query), params)
        new_id = cur.lastrowid
    else:
        cur.execute(query + " RETURNING id", params)
        new_id = cur.fetchone()["id"]
    conn.commit()
    return new_id


def init_schema():
    """Create tables if they do not exist yet. Safe to call on every start."""
    if _is_sqlite():
        id_col = "INTEGER PRIMARY KEY AUTOINCREMENT"
        ts = "TIMESTAMP"
    else:
        id_col = "BIGSERIAL PRIMARY KEY"
        ts = "TIMESTAMPTZ"
    statements = [
        f"""CREATE TABLE IF NOT EXISTS deli_tickets (
              id          {id_col},
              customer    VARCHAR(100) NOT NULL,
              item        VARCHAR(100) NOT NULL,
              notes       VARCHAR(500) NOT NULL DEFAULT '',
              status      VARCHAR(20)  NOT NULL DEFAULT 'WAITING',
              created_at  {ts} NOT NULL,
              done_at     {ts},
              done_by     VARCHAR(100)
            )""",
        # SAME columns as the Java app's activity_log (schema.sql) so both apps share one notebook
        f"""CREATE TABLE IF NOT EXISTS activity_log (
              id          {id_col},
              occurred_at {ts} NOT NULL,
              service     VARCHAR(50)  NOT NULL,
              actor       VARCHAR(100) NOT NULL,
              action      VARCHAR(100) NOT NULL,
              method      VARCHAR(10),
              path        VARCHAR(500),
              status      INTEGER,
              details     TEXT
            )""",
        "CREATE INDEX IF NOT EXISTS idx_activity_log_occurred_at ON activity_log (occurred_at DESC)",
    ]
    for stmt in statements:
        execute(stmt)


def now():
    return datetime.now(timezone.utc)


def to_dict(row):
    """Turn a database row (sqlite Row or psycopg dict) into a plain JSON-friendly dict."""
    if row is None:
        return None
    out = {}
    for key in row.keys():
        value = row[key]
        if isinstance(value, datetime):
            value = value.isoformat()
        out[key] = value
    return out


# ---- tickets -----------------------------------------------------------------
MENU = [
    {"item": "Turkey sandwich", "emoji": "🥪", "price": 6.50},
    {"item": "Veggie wrap", "emoji": "🌯", "price": 5.75},
    {"item": "Chicken soup", "emoji": "🍲", "price": 4.25},
    {"item": "Caesar salad", "emoji": "🥗", "price": 5.50},
    {"item": "Fruit cup", "emoji": "🍓", "price": 3.00},
]


def create_ticket(customer, item, notes=""):
    return insert_returning_id(
        "INSERT INTO deli_tickets (customer, item, notes, status, created_at) VALUES (%s, %s, %s, 'WAITING', %s)",
        (customer, item, notes or "", now()),
    )


def list_tickets(customer=None):
    if customer:
        return execute(
            "SELECT * FROM deli_tickets WHERE customer = %s ORDER BY id DESC", (customer,), fetch="all"
        )
    return execute("SELECT * FROM deli_tickets ORDER BY id DESC", fetch="all")


def get_ticket(ticket_id):
    return execute("SELECT * FROM deli_tickets WHERE id = %s", (ticket_id,), fetch="one")


def mark_done(ticket_id, worker):
    execute(
        "UPDATE deli_tickets SET status = 'DONE', done_at = %s, done_by = %s WHERE id = %s",
        (now(), worker, ticket_id),
    )


# ---- activity log --------------------------------------------------------------
def log_activity(actor, action, method=None, path=None, status=None, details=None):
    try:
        execute(
            "INSERT INTO activity_log (occurred_at, service, actor, action, method, path, status, details) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
            (now(), current_app.config["SERVICE_NAME"], actor or "anonymous", action, method, path, status, details),
        )
    except Exception as exc:  # a broken notebook must never stop the deli
        current_app.logger.warning("could not write activity log: %s", exc)


def recent_activity(limit=200):
    return execute("SELECT * FROM activity_log ORDER BY occurred_at DESC LIMIT %s", (limit,), fetch="all")
