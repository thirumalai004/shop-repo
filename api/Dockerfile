# ---- base: runtime dependencies ----
FROM python:3.12-slim AS base
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- test: dev tooling + tests (used by Jenkins, never deployed) ----
FROM base AS test
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY . .
CMD ["pytest"]

# ---- runtime: small, non-root, only the app code ----
FROM base AS runtime
ARG APP_VERSION=dev
ARG GIT_COMMIT=unknown
ENV APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT}
RUN useradd --create-home --uid 10001 appuser
COPY --chown=appuser:appuser app.py .
USER appuser
EXPOSE 5000
CMD ["gunicorn", "-b", "0.0.0.0:5000", "--workers", "2", "--access-logfile", "-", "app:app"]
