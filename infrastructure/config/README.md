# Sentinel read-only configuration planner

**Experimental, read-only implementation. Does not replace `infrastructure/level1/sentinel.ps1`.**

The public platform repo contains the loader and policy enforcement; the separate **private** `orzujon/sentinel-environment-config` repo supplies environment YAML. Secrets are **not** fetched, and image approval is **not** implemented.

## Dependencies

Python 3.10+ and PyYAML. Install only into a virtual environment:

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install "PyYAML==6.0.2"
```

## Offline demonstration using a synthetic fixture

```powershell
.\.venv\Scripts\python.exe infrastructure\config\plan.py --config-file infrastructure\config\fixtures\lab.example.yaml --environment lab
.\.venv\Scripts\python.exe -m unittest discover -s infrastructure\config\tests -p "test_*.py" -v
```

## Inspect the private configuration repository at an immutable commit

```powershell
git clone --no-checkout git@github.com:orzujon/sentinel-environment-config.git C:\Sentinel\config-readonly
$revision = (git -C C:\Sentinel\config-readonly rev-parse HEAD)
.\.venv\Scripts\python.exe infrastructure\config\plan.py --config-repo C:\Sentinel\config-readonly --revision $revision --environment lab
```

Use an appropriately restricted, read-only credential on a dedicated runner in future. The current command reads an **existing local clone** via `git show` and does not perform a pull, download, checkout, apply, or secret resolution. The operator controls when the clone is refreshed. Only the explicitly pinned full commit is read.

This demonstration accepts the approved GitHub origin URL, but **does not verify signed Git commits or provenance**, host capacities, image signatures or catalog membership. It is not a deployment authorisation. The output's `planSha256` is a deterministic summary fingerprint, **not** a signature or deployable approval token.

See `docs/architecture/adr-0001-config-and-secrets.md` on the architecture proposal branch for future design.
