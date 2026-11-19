"""to-do-list-api: API de tareas con persistencia en RDS (PostgreSQL),
credenciales leídas de Secrets Manager en tiempo de ejecución y
métricas propias publicadas en CloudWatch."""
import json
import logging
import os
from datetime import datetime, timezone
from functools import lru_cache

import boto3
import psycopg2
import psycopg2.extras
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

logger = logging.getLogger("todo-api")
logging.basicConfig(level=logging.INFO)

METRIC_NAMESPACE = "TodoApp"
app = FastAPI(title="to-do-list-api")


# ---------------------------------------------------------------- config
def app_version() -> str:
    return os.getenv("APP_VERSION", "dev")


def aws_region() -> str:
    return os.getenv("AWS_REGION", "us-east-1")


# ------------------------------------------------------------ CloudWatch
@lru_cache(maxsize=1)
def _cloudwatch():
    return boto3.client("cloudwatch", region_name=aws_region())


def emit_metric(name: str, value: float, unit: str = "Count") -> None:
    """Publica una métrica propia. Nunca debe tumbar la app si CloudWatch falla."""
    try:
        _cloudwatch().put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[{"MetricName": name, "Value": value, "Unit": unit}],
        )
    except Exception:  # noqa: BLE001
        logger.exception("No se pudo publicar la métrica %s", name)


# ------------------------------------------------------- Secrets Manager
@lru_cache(maxsize=1)
def get_db_credentials() -> dict:
    """Lee las credenciales de RDS desde Secrets Manager (no hay nada hardcodeado)."""
    secret_name = os.environ["DB_SECRET_NAME"]
    client = boto3.client("secretsmanager", region_name=aws_region())
    response = client.get_secret_value(SecretId=secret_name)
    return json.loads(response["SecretString"])


# ------------------------------------------------------------------- DB
def get_conn():
    creds = get_db_credentials()
    return psycopg2.connect(
        host=creds["host"],
        port=creds.get("port", 5432),
        dbname=creds["dbname"],
        user=creds["username"],
        password=creds["password"],
        connect_timeout=3,
    )


_CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS tasks (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    done BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
"""


def check_db() -> None:
    conn = get_conn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
    finally:
        conn.close()


def db_list_tasks() -> list:
    conn = get_conn()
    try:
        with conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(_CREATE_TABLE)
            cur.execute("SELECT id, title, done, created_at FROM tasks ORDER BY id")
            rows = cur.fetchall()
        return [
            {**r, "created_at": r["created_at"].isoformat()} for r in rows
        ]
    finally:
        conn.close()


def db_create_task(title: str, done: bool) -> tuple:
    """Inserta la tarea y regresa (tarea, número de tareas pendientes)."""
    conn = get_conn()
    try:
        with conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(_CREATE_TABLE)
            cur.execute(
                "INSERT INTO tasks (title, done) VALUES (%s, %s) "
                "RETURNING id, title, done, created_at",
                (title, done),
            )
            row = cur.fetchone()
            cur.execute("SELECT COUNT(*) AS n FROM tasks WHERE done = FALSE")
            pending = cur.fetchone()["n"]
        task = {**row, "created_at": row["created_at"].isoformat()}
        return task, pending
    finally:
        conn.close()


def run_db(fn):
    """Ejecuta una operación de BD y reporta la métrica RDSErrors (1 si falla, 0 si no)."""
    try:
        result = fn()
    except Exception:  # noqa: BLE001
        logger.exception("Error al acceder a RDS")
        emit_metric("RDSErrors", 1)
        raise HTTPException(status_code=503, detail="Database error")
    emit_metric("RDSErrors", 0)
    return result


# ------------------------------------------------------------- modelos
class TaskIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    done: bool = False


# ------------------------------------------------------------ endpoints
@app.get("/tasks")
def list_tasks():
    tasks = run_db(db_list_tasks)
    # Métrica propia: tareas pendientes (done = false)
    emit_metric("PendingTasks", sum(1 for t in tasks if not t["done"]))
    return tasks


@app.post("/tasks", status_code=201)
def create_task(task: TaskIn):
    created, pending = run_db(lambda: db_create_task(task.title, task.done))
    emit_metric("PendingTasks", pending)
    return created


@app.get("/version")
def version():
    return {"version": app_version()}


@app.get("/health")
def health():
    body = {
        "version": app_version(),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    try:
        check_db()
    except Exception:  # noqa: BLE001
        logger.exception("Health check: falló la conexión a la BD")
        emit_metric("RDSErrors", 1)
        return JSONResponse(status_code=503, content={"status": "FAIL", **body})
    emit_metric("RDSErrors", 0)
    return {"status": "OK", **body}
