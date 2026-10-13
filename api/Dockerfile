# --- Base Image ---
FROM python:3.12-slim AS base
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# --- Test Image Target ---
FROM base AS test
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY . .

# --- Runtime Production Target ---
FROM base AS runtime
ARG APP_VERSION=latest
ARG GIT_COMMIT=unknown
LABEL version="${APP_VERSION}" commit="${GIT_COMMIT}"

RUN useradd --create-home --uid 10001 appuser
USER appuser

COPY --chown=appuser:appuser app.py .

EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]