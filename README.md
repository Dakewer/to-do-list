# to-do-list-api

API de tareas (FastAPI + PostgreSQL en RDS) desplegada en EC2 con Terraform, CI/CD con GitHub Actions y observabilidad con CloudWatch.

## Arquitectura

```
GitHub ──PR──▶ CI (pytest) ──▶ merge a main
   │
   └─ tag vX.Y.Z ──▶ release.yml (zip) ──▶ release publicado ──▶ deploy.yml (SSH a la EC2)

provision.yml ──▶ Terraform ──▶ EC2 (user_data: clona repo + systemd) ──▶ RDS PostgreSQL
                      │                    │  lee credenciales             ▲
                      │                    ▼                                │
                      │            Secrets Manager ─────────────────────────┘
                      │                    │ put_metric_data
                      ▼                    ▼
              S3 (tfstate)       CloudWatch (métricas, alarmas, dashboard) ──▶ SNS ──▶ correo
```

## Endpoints

| Endpoint | Descripción |
|---|---|
| `GET /tasks` | Lista las tareas |
| `POST /tasks` | Crea una tarea (`{"title": "...", "done": false}`) |
| `GET /version` | Versión desplegada (variable de ambiente `APP_VERSION`) |
| `GET /health` | `OK`/`FAIL` según la conexión a RDS, más versión y timestamp (503 si falla) |

## Métricas, alarmas y dashboard

| Métrica | Origen | Alarma |
|---|---|---|
| `AWS/EC2 CPUUtilization` | Nativa de AWS | Promedio > 70% en 2 de 3 periodos de 5 min |
| `TodoApp/RDSErrors` | Propia (`put_metric_data`): 1 por cada error de lectura/escritura en RDS, 0 en éxito | Suma >= 1 en 1 min |
| `TodoApp/PendingTasks` | Propia: número de tareas con `done = false` | Máximo > 20 durante 2 periodos de 5 min |

- Las alarmas están definidas en `alerting/alarms.json` y el dashboard en `alerting/cloudwatch-dashboard.json`; Terraform los lee y los crea. Todas notifican al tópico SNS (alarma y recuperación).
- Para validar `RDSErrors`: detén la instancia RDS desde la consola y haz `curl http://<ip>:8000/tasks`; la métrica sube a 1 y la alarma se dispara.

## Requisitos previos (una sola vez)

1. Repositorio **público** en GitHub (la EC2 lo clona sin credenciales).
2. Crear el bucket del tfstate:
   ```bash
   ./scripts/bootstrap-backend.sh <bucket-unico> us-east-1
   ```
3. Secrets del repositorio (*Settings → Secrets and variables → Actions*):

   | Secret | Valor |
   |---|---|
   | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Credenciales del Learner Lab (**cambian en cada sesión**, actualízalas) |
   | `AWS_REGION` | `us-east-1` |
   | `TF_STATE_BUCKET` | Bucket del paso 2 |
   | `ALERT_EMAIL` | Correo para las alarmas |
   | `RELEASE_PAT` | Personal Access Token con permiso `contents: write` (ver nota abajo) |

4. Branch protection para `main` (*Settings → Branches → Add rule*): activar **Require a pull request before merging** y **Require status checks to pass before merging**, seleccionando el check `test` del workflow CI.

> **Por qué `RELEASE_PAT`:** un release creado con el `GITHUB_TOKEN` por defecto no dispara otros workflows, así que `deploy.yml` no se ejecutaría. Con un PAT, el evento `release: published` sí lo activa.

## Crear la infraestructura

*Actions → Provision infrastructure → Run workflow*. Terraform crea EC2, Security Groups, Key Pair, RDS, Secret, SNS, alarmas y dashboard. Cuando termine:

1. Confirma el correo de suscripción de SNS (si no, no llegan las alarmas).
2. Espera 2-3 min a que `user_data` termine y prueba:
   ```bash
   curl -X POST http://<ip>:8000/tasks -H "Content-Type: application/json" \
     -d '{"title": "estudiar para el examen", "done": false}'
   curl http://<ip>:8000/tasks
   curl http://<ip>:8000/version
   curl http://<ip>:8000/health
   ```

Como el Learner Lab se reinicia cada 2 horas: actualiza los secrets de AWS y vuelve a correr *Provision*. El tfstate vive en S3, así que Terraform sabe qué existe y qué no.

## Destruir la infraestructura

*Actions → Destroy infrastructure → Run workflow*.

## Flujo de CI/CD

1. **CI:** al abrir un PR a `main`, corre `pytest`. Con la branch protection, no se puede hacer merge si falla.
2. **Release:** `git tag v1.0.0 && git push origin v1.0.0` crea el release con `todo-list-api-v1.0.0.zip`.
3. **Deploy:** al publicarse el release, la EC2 descarga el zip, instala dependencias, actualiza `APP_VERSION` y reinicia el servicio. El workflow termina verificando `GET /version`. También se puede lanzar a mano con un tag.
4. **Health check:** cada 5 minutos consulta `GET /health`; falla si la respuesta no es `OK` (o si no hay infraestructura).

## Correr localmente

```bash
pip install -r src/requirements.txt -r tests/requirements.txt
pytest                      # pruebas (no usan AWS)
```

Para levantar la API necesitas un secret en AWS y credenciales configuradas:

```bash
export DB_SECRET_NAME=todo-list/db-credentials AWS_REGION=us-east-1 APP_VERSION=dev
cd src && uvicorn main:app --port 8000
```

## Estructura

```
src/main.py, src/requirements.txt
tests/test_main.py
terraform/        main.tf, variables.tf, outputs.tf, user_data.sh.tpl
alerting/         cloudwatch-dashboard.json, alarms.json
scripts/          bootstrap-backend.sh, deploy_remote.sh
.github/workflows provision, destroy, ci, release, deploy, health-check
```

## Notas de seguridad

- El tfstate nunca se sube al repo (`.gitignore`) y contiene la llave SSH y la contraseña de RDS: el bucket tiene el acceso público bloqueado.
- Las credenciales de RDS no están en el código: la app las lee de Secrets Manager en tiempo de ejecución.
- Los puertos 22 y 8000 están abiertos a `0.0.0.0/0` por simplicidad de la práctica; en producción se restringirían.
