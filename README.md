# Shop: zero-downtime blue-green deployments with Docker + Jenkins

```
 client ──▶ nginx :${HTTP_PORT} ──▶ api-blue   ┐
                  │  (active_upstream.conf)   ├──▶ db (Postgres, named volume)
                  └─────▶ api-green  ┘            ▲
                                       worker ─────┘
```

Only one API color receives traffic. A release deploys to the **idle** color, waits for its
healthcheck, flips Nginx (graceful reload, no dropped requests), verifies, and keeps the old color
running so rollback is just another reload.

## Repository layout

| Path | Purpose |
|---|---|
| `api/`, `worker/` | Services, Dockerfiles (multi-stage, non-root), tests |
| `nginx/` | `nginx.conf` + generated `active_upstream.conf` (gitignored) |
| `docker-compose.yml` | The stack: db, api-blue, api-green, worker, nginx |
| `docker-compose.test.yml` | Throw-away stack for integration tests |
| `scripts/switch.sh` | Blue-green controller (init, deploy-idle, switch, verify, rollback...) |
| `scripts/loadtest.sh` | Request loop used to prove zero downtime |
| `jenkins/` | Jenkins image (docker CLI + plugins) and compose file with a local registry |
| `Jenkinsfile` | The pipeline |

## 1. Start Jenkins and the registry

```bash
sudo mkdir -p /var/jenkins_home
cd jenkins
docker compose up -d --build
docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```
Open http://localhost:8081, paste the password, and install the suggested plugins
(the custom image already includes the pipeline/docker/credentials plugins).

`/var/jenkins_home` is mounted at the same path on host and container on purpose: the pipeline
runs `docker compose` and `docker run -v` against the **host** Docker daemon, so paths must match.

## 2. Create credentials (Manage Jenkins > Credentials)

| ID | Type | Value |
|---|---|---|
| `registry-creds` | Username with password | Anything for the local `registry:2` (it has no auth); real creds for Docker Hub/GHCR |
| `shop-env-file` | Secret file | Your filled-in copy of `.env.example` |

## 3. Create the pipeline job

1. New Item > **Pipeline** > name it `shop`.
2. Pipeline definition: *Pipeline script from SCM*, Git, your repo URL, script path `Jenkinsfile`.
3. Do **not** enable "Clean before checkout" (the workspace stores deployment state).
4. Trigger: SCM polling is preconfigured in the `Jenkinsfile`; or add a GitHub/GitLab webhook to
   `http://<jenkins>:8081/github-webhook/` and tick "GitHub hook trigger".
5. Run once so Jenkins registers the parameters, then use **Build with Parameters**.

## 4. First deployment

Run *Build with Parameters* (`ENVIRONMENT=dev`). The first run bootstraps the stack
(`switch.sh init`): both colors start with the new tag and **blue is live**.
Check it:

```bash
curl http://localhost:8088/health
# {"color":"blue","commit":"1a2b3c4","status":"ok","version":"1"}
```

## 5. Normal releases

Push a commit (or trigger a build). The pipeline:

1. Checkout, load `.env` from Jenkins credentials
2. hadolint + flake8, unit tests (JUnit + coverage artifact)
3. Build images (`api` embeds `APP_VERSION` and `GIT_COMMIT`)
4. Integration tests in a disposable Compose stack (optional)
5. Trivy scan (fails on HIGH/CRITICAL fixable vulnerabilities)
6. Push to the registry
7. Deploy to the idle color and wait for `healthy`
8. Manual approval (**prod only**)
9. Switch traffic, verify `/health` through Nginx reports the new version
10. Roll the worker to the new tag

If anything fails **after** the switch, the `post { failure }` block flips traffic back automatically.

## 6. Prove zero downtime

Terminal 1:
```bash
scripts/loadtest.sh
```
Terminal 2 (or Jenkins): run a new build. During *Switch Traffic* the output changes
from `"version":"1" "color":"blue"` to `"version":"2" "color":"green"` and every line stays `200`.
Press Ctrl+C for `SUMMARY: ok=... failed=0`. Save this plus `deploy.log` as evidence.

## 7. Rollback

* **Automatic:** failure after the switch (e.g. verification).
* **Manual:** *Build with Parameters* with `ROLLBACK=true`, or on the host
  `cd /var/jenkins_home/workspace/shop && scripts/switch.sh rollback`.

Audit trail: `deploy.log` in the workspace (time, environment, actor, event). Set
`DEPLOY_WEBHOOK_URL` in `.env` to also POST each event to a webhook.

## 8. Failure drills

| Drill | How | Expected |
|---|---|---|
| Bad image | Make `/health` raise at startup | Fails in *Deploy Idle Color*; traffic never moved |
| Failed verification | Hardcode a wrong `APP_VERSION` in the Dockerfile | Auto-rollback, `ROLLBACK` line in `deploy.log` |
| Vulnerable image | Use an old base image (e.g. `python:3.8-slim`) | *Vulnerability Scan* fails before push |
| Lint failure | Add an unused import to `app.py` | *Static Analysis* fails |
| Prod gate | `ENVIRONMENT=prod` | Pipeline pauses at *Approval* |

## Notes and limits

* **Database migrations:** both colors share one DB, so migrations must be backward compatible
  (add first, remove in a later release). Alembic would be an extra stage before *Deploy Idle Color*.
* **Worker** is updated only after verification succeeds; it is not blue-green.
* **Environments** (`dev/staging/prod`) are logical on one host. For real separation use separate
  hosts (`DOCKER_HOST`), separate Jenkins nodes, or separate compose projects.
* **Trivy findings** depend on upstream images; if a base image has an unfixed-by-you CVE, bump the
  base tag or add a `.trivyignore`.
* The Jenkins container runs as root with the Docker socket mounted: acceptable for a lab,
  not for production (use dedicated agents).
* Old color keeps running after a switch (that is your rollback target). Next deploy replaces it.

## Changing ports

* **Shop (nginx):** set `HTTP_PORT` in `.env` (and in the Jenkins `shop-env-file` credential). `.env.example` uses 8088.
  Then run `scripts/loadtest.sh` (it reads `HTTP_PORT`, or pass a URL).
* **Jenkins UI:** edit the `"8081:8080"` mapping in `jenkins/docker-compose.yml`.
* **Registry:** if 5000 is taken, change the mapping there, `REGISTRY` in `.env`, and `REGISTRY` in the `Jenkinsfile`
  (it must stay `localhost:<port>` so Docker treats it as an insecure local registry).
