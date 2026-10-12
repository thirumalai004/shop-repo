import logging
import os
import time

import psycopg2

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worker")


def connect():
    while True:
        try:
            return psycopg2.connect(
                host=os.getenv("POSTGRES_HOST", "db"),
                dbname=os.getenv("POSTGRES_DB", "shop"),
                user=os.getenv("POSTGRES_USER", "shop"),
                password=os.getenv("POSTGRES_PASSWORD", ""),
                connect_timeout=3,
            )
        except psycopg2.Error as exc:
            log.warning("db not ready (%s); retrying in 3s", exc)
            time.sleep(3)


def main():
    conn = connect()
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS heartbeat ("
            "id SERIAL PRIMARY KEY, ts TIMESTAMPTZ NOT NULL DEFAULT now())"
        )
    log.info("worker started")
    while True:
        try:
            with conn.cursor() as cur:
                cur.execute("INSERT INTO heartbeat DEFAULT VALUES")
            log.info("heartbeat written")
        except psycopg2.Error as exc:
            log.error("write failed: %s; reconnecting", exc)
            conn = connect()
            conn.autocommit = True
        time.sleep(10)


if __name__ == "__main__":
    main()
