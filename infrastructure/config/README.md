# Sentinel read-only configuration planner

**Experimental, read-only implementation. Does not replace `infrastructure/level1/sentinel.ps1`.**

The public platform repo contains the loader and policy enforcement; the separate **private** `orzujon/sentinel-environment-config` repo supplies environment YAML. Secrets are **not** fetched, and image approval is **not** implemented.

## Dependencies

Python 3.10+ and PyYAML. Install only into a virtual environment:

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install "PyYAML==6.0.3"
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

See `docs/architecture/adr-0001-config-and-secrets.md` in this branch for the architecture decision.

## Experimental independent image-catalog inspection

The image catalog checker is **offline and non-destructive**. It checks that a
catalog file matches a SHA256 digest provided **separately** from private YAML,
that the requested image ID has an `approved` catalog entry, and that the
digest, version and upstream identity agree. It does **not** validate an
upstream OpenPGP signature or prove who approved the catalog. Thus even a
metadata match prints `deploymentPermitted: false` and
`artifactSignatureVerified: false`.

The public `fixtures/catalog.example.json` deliberately contains a
**candidate without a digest**, so using it as an approved catalog fails
closed. Never copy a synthetic digest from tests into an operational catalog.

An operator can inspect the candidate rejection offline:

```powershell
$catalog = "infrastructure\config\fixtures\catalog.example.json"
$catalogPin = (Get-FileHash $catalog -Algorithm SHA256).Hash.ToLowerInvariant()
.\.venv\Scripts\python.exe infrastructure\config\plan.py `
  --config-file infrastructure\config\fixtures\lab.example.yaml `
  --environment lab --catalog-file $catalog --catalog-sha256 $catalogPin
# Expected BLOCKED: candidate is not approved
```

A production catalog approval system is a **later** milestone: signed source
evidence, reviewer identity attestation, a separate protected catalog revision,
immutable artifacts, and revocation handling must be implemented before
provisioning may trust the catalog. Hashing the file locally in this demonstration
**does not by itself constitute approval**. A moving catalog from the private
environment configuration repository is not an independent approval source.

The plan fingerprint now includes catalog pin and resolved image digest if a
catalog is supplied. No new VM creation command or privileged runner is added.

## First real image — verified candidate (not approved)

`infrastructure/image-catalog/candidates/ubuntu-26.04-20261016.json`
records the **operator-reported** local integrity, Canonical `gpgv` signature
and signed manifest comparison results for Ubuntu release build `20261016`.
The observed artifact SHA256 is
`5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5`.
The reported signing key fingerprint is
`D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81`.

This evidence is **not a machine-generated signed attestation**. The public
record deliberately omits local paths, raw signed manifests, credentials
and machine identities. It has `state: candidate` and
`deploymentPermitted: false`. The separate catalog example is still an
unapproved fixture. No production catalog approval has been minted.

**Next security gate:** capture a reproducible verification report that
rechecks the actual artifact against the signed manifest with a trusted
signing key; pin a reviewed catalog revision independently of private YAML;
record an explicit approver decision and revocation policy. Only a future,
separately reviewed provisioning integration may consume that approval.
