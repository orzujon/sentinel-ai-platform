# ADR 0001 — Separate source code, environment configuration, and secrets

- **Status:** Proposed for review; not implemented
- **Scope:** Sentinel AI Platform, Level 1 Hyper-V provisioning and future services
- **Review branches:** Platform `proposal/yaml-configuration-boundary`; config `proposal/lab-yaml-inventory`

## Decision proposed

1. **Public code repository — `sentinel-ai-platform`.** PowerShell, shell helpers, Ansible, application code, tests, schemas, pipelines, and non-environment-specific examples.
2. **Private configuration repository — `sentinel-environment-config`.** Per-environment YAML: VM inventory, size, image digest, networking, ownership, host paths, policy, and **opaque secret references**. No credentials, private keys, tokens or generated cloud-init files.
3. **Secret store — future dedicated service.** Real secret values and rotation policies live outside both Git repositories. For the current Linux lab, SSH public-key injection does **not** require fetching a private key; the private key remains on the operator's machine.
4. **Trusted execution runner — local Windows host initially.** Resolve a pinned configuration commit, validate schema and policy, check host state, require approval, then provision and run guest-health checks. The management runner remains outside disposable VMs.

## Why

- Git history makes VM provisioning **reviewable** and reproducible; a private Git repo does not make plaintext secrets safe.
- One reusable command can target different approved environments without embedding names, memory or IP addresses inside executable source.
- Prevent a public PR or untrusted GitHub Actions runner from automatically making privileged Hyper-V changes.

## Execution contract (target design, not yet implemented)

```text
operator -> select environment + config commit SHA
             |
             v
trusted runner obtains YAML from private config repo (read-only identity)
             |
             v
validate YAML schema + safe policy/allowlists + protected resource exclusions
             |
             v
read-only plan (host capacity, route collisions, image checksum, ownership)
             |
             v
separate explicit approval of exactly the proposed plan + commit SHA
             |
             v
resolve only required secrets by reference (when needed)
             |
             v
generate local ephemeral data with restrictive ACLs; redact logs
             |
             v
provision -> verify fixed RAM + actual SSH + cloud-init + sudo
             |
             v
publish non-sensitive JSON/JSONL evidence; clean up sensitive temporary files
```

### Security requirements

- Pin the **code revision, config revision and approved Ubuntu SHA256** in each run report. Do not use a moving `main` branch during apply.
- Config is **data**, never arbitrary PowerShell, shell commands, or unchecked template expressions. Validate types, lengths, IPv4 overlaps, paths, uniqueness and allowlists before effects.
- A private GitHub repo alone is not a secret manager. Secret references (e.g. `vault://sentinel/lab/example`) are not secret values. The runner refuses unsupported references or missing secret-provider integration instead of falling back to plaintext.
- Never put resolved secrets into CLI arguments, persistent environment variables, workflow logs, Git commits, issue bodies, unencrypted build artifacts, or `runs/`. Some provisioning tools necessarily consume a temporary file; protect its file permissions, bound its lifetime, and delete it on both success and failure. Avoid writing secret material into persistent VM seed disks where possible.
- **No privileged Hyper-V operations from untrusted PR workflows.** GitHub-hosted CI performs syntax, schema and unit tests only. Explicitly gated provisioning belongs to an isolated, permission-limited, approved local runner.
- Use deny-by-default environment/VM identity rules and protect preexisting `k8s-cp01`, `k8s-w01` and `Sentinel-K8s` until an independently reviewed policy changes.
- Changing a configuration file never, by itself, provisions a VM.

## Migration without breaking the verified baseline

1. Keep PR #1 (import) in draft while addressing its test/config and stale documentation issues.
2. Introduce versioned YAML schema and **read-only** loader; add tests for valid and invalid configurations.
3. Adapt existing Stage 1–3 modules to receive normalized **validated** config objects, while keeping current safety gates.
4. Run `infra-plan` under the new loader against a synthetic environment; compare with the old read-only plan.
5. After review, conduct a fresh isolated provision + SSH/cloud-init/sudo/RAM regression test. Never destroy the verified VMs to test migration.
6. Add an explicit approval handshake for an immutable plan ID/config commit before privileged apply.
7. Integrate a real secret provider **only when a workload requires secrets**, then add redaction and cleanup tests.

## Unresolved review questions

- Where should the privileged Windows runner live when we move off the desktop?
- Which secret store (Vault, cloud KMS-backed manager, or similar) will we adopt?
- How do we handle encrypted at-rest temporary files and access control for Windows/WSL?
- Which environments will be eligible for automated apply, and who approves each?
- Should the public code repository remain public once we add runner deployment instructions?

**No live infrastructure is changed by this ADR.**
