import pytest
from fastapi.testclient import TestClient

import main

client = TestClient(main.app)


@pytest.fixture(autouse=True)
def no_aws(monkeypatch):
    """Las pruebas no tocan AWS: las métricas se capturan en una lista."""
    emitted = []
    monkeypatch.setattr(main, "emit_metric", lambda name, value, unit="Count": emitted.append((name, value)))
    return emitted


def test_version_reads_env(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v1.2.3")
    r = client.get("/version")
    assert r.status_code == 200
    assert r.json() == {"version": "v1.2.3"}


def test_health_ok(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v1.0.0")
    monkeypatch.setattr(main, "check_db", lambda: None)
    r = client.get("/health")
    body = r.json()
    assert r.status_code == 200
    assert body["status"] == "OK"
    assert body["version"] == "v1.0.0"
    assert "timestamp" in body


def test_health_fail_reports_rds_error(monkeypatch, no_aws):
    def boom():
        raise RuntimeError("db down")

    monkeypatch.setattr(main, "check_db", boom)
    r = client.get("/health")
    assert r.status_code == 503
    assert r.json()["status"] == "FAIL"
    assert ("RDSErrors", 1) in no_aws


def test_list_tasks_emits_pending_metric(monkeypatch, no_aws):
    tasks = [
        {"id": 1, "title": "a", "done": False, "created_at": "x"},
        {"id": 2, "title": "b", "done": True, "created_at": "x"},
        {"id": 3, "title": "c", "done": False, "created_at": "x"},
    ]
    monkeypatch.setattr(main, "db_list_tasks", lambda: tasks)
    r = client.get("/tasks")
    assert r.status_code == 200
    assert len(r.json()) == 3
    assert ("PendingTasks", 2) in no_aws


def test_create_task_ok(monkeypatch, no_aws):
    def fake_create(title, done):
        return {"id": 7, "title": title, "done": done, "created_at": "x"}, 4

    monkeypatch.setattr(main, "db_create_task", fake_create)
    r = client.post("/tasks", json={"title": "estudiar", "done": False})
    assert r.status_code == 201
    assert r.json()["title"] == "estudiar"
    assert ("PendingTasks", 4) in no_aws


def test_create_task_validates_title():
    r = client.post("/tasks", json={"title": "", "done": False})
    assert r.status_code == 422


def test_db_error_returns_503_and_metric(monkeypatch, no_aws):
    def boom():
        raise RuntimeError("db down")

    monkeypatch.setattr(main, "db_list_tasks", boom)
    r = client.get("/tasks")
    assert r.status_code == 503
    assert ("RDSErrors", 1) in no_aws
