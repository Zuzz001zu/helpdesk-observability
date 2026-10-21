# The helpdesk API, unchanged, with OpenTelemetry auto-instrumentation added around it.
# This is how most applications get onboarded: no code change, only packages and
# environment variables (see docs/onboarding.md).

FROM python:3.12-slim AS source
ARG HELPDESK_REPO=https://github.com/Zuzz001zu/helpdesk-api.git
ARG HELPDESK_REF=main
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$HELPDESK_REF" "$HELPDESK_REPO" /src

FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /app

COPY --from=source /src/requirements.txt requirements-app.txt
COPY requirements-otel.txt .
RUN pip install --no-cache-dir -r requirements-app.txt -r requirements-otel.txt

COPY --from=source /src/alembic.ini .
COPY --from=source /src/alembic ./alembic
COPY --from=source /src/app ./app
COPY log-config.json .

RUN useradd --create-home appuser
USER appuser
EXPOSE 8000

# opentelemetry-instrument wraps the normal start command. The log configuration lets
# uvicorn's access log reach the root logger, where OpenTelemetry picks it up.
CMD ["sh", "-c", "alembic upgrade head && opentelemetry-instrument uvicorn app.main:app --host 0.0.0.0 --port 8000 --log-config log-config.json"]
