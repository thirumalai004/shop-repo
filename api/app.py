import os

import psycopg2
from flask import Flask, jsonify

app = Flask(__name__)


def get_conn():
    return psycopg2.connect(
        host=os.getenv("POSTGRES_HOST", "db"),
        dbname=os.getenv("POSTGRES_DB", "shop"),
        user=os.getenv("POSTGRES_USER", "shop"),
        password=os.getenv("POSTGRES_PASSWORD", ""),
        connect_timeout=3,
    )


@app.get("/health")
def health():
    """Liveness + identity: tells you WHICH version/color is answering."""
    return jsonify(
        status="ok",
        version=os.getenv("APP_VERSION", "dev"),
        commit=os.getenv("GIT_COMMIT", "unknown"),
        color=os.getenv("COLOR", "unknown"),
    )


@app.get("/")
def index():
    return jsonify(message="shop api")


@app.get("/stats")
def stats():
    """Reads the table the worker writes to (proves shared DB access)."""
    conn = None
    try:
        conn = get_conn()
        with conn, conn.cursor() as cur:
            cur.execute(
                "CREATE TABLE IF NOT EXISTS heartbeat ("
                "id SERIAL PRIMARY KEY, ts TIMESTAMPTZ NOT NULL DEFAULT now())"
            )
            cur.execute("SELECT count(*) FROM heartbeat")
            count = cur.fetchone()[0]
        return jsonify(heartbeats=count)
    except psycopg2.Error as exc:
        return jsonify(error="database unavailable", detail=str(exc)), 503
    finally:
        if conn is not None:
            conn.close()
