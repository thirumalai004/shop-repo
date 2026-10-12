"""Runs inside the docker-compose.test.yml network against a real API + Postgres."""
import json
import os
import urllib.request

BASE = os.getenv("API_URL", "http://api:5000")


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=5) as resp:
        return resp.status, json.load(resp)


def test_health_has_expected_version():
    status, body = get("/health")
    assert status == 200
    assert body["status"] == "ok"
    expected = os.getenv("EXPECTED_VERSION")
    if expected:
        assert body["version"] == expected


def test_stats_reaches_database():
    status, body = get("/stats")
    assert status == 200
    assert body["heartbeats"] >= 0
