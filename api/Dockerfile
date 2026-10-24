FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY api/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --uid 10001 --create-home sentinel

# Build from repository root, so curated runbooks are included in the image.
COPY --chown=sentinel:sentinel api/main.py api/retrieval.py api/quality.py api/__init__.py ./api/
COPY --chown=sentinel:sentinel knowledge/runbooks/ ./knowledge/runbooks/

USER sentinel

EXPOSE 8000
CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]
