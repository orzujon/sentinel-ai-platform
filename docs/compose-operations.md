# Run Sentinel with Docker Compose

This lab uses your existing NVIDIA GPU and **reuses** the already-downloaded
Llama 3.2 1B model from Docker volume `ai-ollama-data`.

**Security boundaries:** Both ports bind to `127.0.0.1`. The API has no
authentication yet. Never expose it publicly or send it confidential data.
Only run synthetic incident reports.

## One-time migration from manually run containers (Windows PowerShell)

Start in `$HOME\projects\sentinel-ai-platform`.

1. Check that the Ollama model is present, and verify the original named volume:

   ```powershell
   docker exec ai-ollama ollama list
   docker inspect ai-ollama --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{println}}{{end}}'
   docker volume inspect ai-ollama-data --format '{{.Name}}'
   ```

   The mount must include `ai-ollama-data -> /root/.ollama`.
   If not, **stop and check your setup rather than continuing**.

2. Stop the two **manually started** containers to free host ports 8000 and 11434:

   ```powershell
   docker stop sentinel-api
   docker stop ai-ollama
   ```

   These stop commands do **not** delete the model volume. Keep the old
   `ai-ollama` container stopped as a rollback option, and do not start
   it concurrently with the Compose-managed Ollama instance.

3. Validate the configuration and start the stack:

   ```powershell
   git pull --ff-only
   docker compose config -q
   docker compose up -d --build
   docker compose ps
   ```

4. Verify that Sentinel and Ollama can communicate:

   ```powershell
   Invoke-RestMethod http://127.0.0.1:8000/healthz
   Invoke-RestMethod http://127.0.0.1:8000/readyz
   docker compose exec ollama ollama list
   docker compose exec ollama ollama ps
   ```

   `ollama ps` may be empty if no inference has recently run. To check
   GPU use while the model is loaded, run an investigation and then use
   `docker compose exec ollama ollama ps`.

## Operations

- Start: `docker compose up -d`
- Rebuild after API changes: `docker compose up -d --build`
- Inspect containers: `docker compose ps`
- Follow logs: `docker compose logs -f --tail=100`
- Stop for gaming: `docker compose stop`
- Resume: `docker compose start`
- Stop and remove Compose containers/network: `docker compose down`
  (the model volume is marked **external** and is not managed by Compose)

**Never delete `ai-ollama-data`** unless you consciously intend to delete
all downloaded models and related Ollama data. The original `ai-ollama`
container is not managed by Compose and remains stopped after migration.

## Troubleshooting

- `port is already allocated`: another container (often `ai-ollama`)
  still owns 11434, or `sentinel-api` owns 8000.
  Use `docker ps` to find it.
- `external volume not found`: verify the old model volume name before
  starting; do not create an empty replacement just to hide the problem.
- `no compatible GPU`: check Docker Desktop WSL2 GPU integration,
  `nvidia-smi`, and Docker Compose GPU capability.
- `/healthz=200`, `/readyz=503`: API is alive but inference dependency
  is inaccessible or the specified model is missing. Check
  `docker compose logs ollama` and `docker compose exec ollama ollama list`.

## Reproducibility limitations

This is a *local migration* configuration relying on an external data volume.
A brand-new machine needs its own NVIDIA GPU configuration, a model volume and
an explicit model pull. Pin image digests and Python package versions before
claiming repeatable production builds. Neither a working health check nor
`docker compose up` proves model diagnostic accuracy or banking compliance.
