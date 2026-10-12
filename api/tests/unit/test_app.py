import psycopg2

import app as app_module


def client():
    app_module.app.config["TESTING"] = True
    return app_module.app.test_client()


def test_health_reports_version_and_color(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "42")
    monkeypatch.setenv("GIT_COMMIT", "abc1234")
    monkeypatch.setenv("COLOR", "green")
    resp = client().get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body == {"status": "ok", "version": "42", "commit": "abc1234", "color": "green"}


def test_index():
    resp = client().get("/")
    assert resp.status_code == 200
    assert resp.get_json()["message"] == "shop api"


def test_stats_returns_503_when_db_down(monkeypatch):
    def boom():
        raise psycopg2.OperationalError("db down")

    monkeypatch.setattr(app_module, "get_conn", boom)
    resp = client().get("/stats")
    assert resp.status_code == 503
    assert resp.get_json()["error"] == "database unavailable"
