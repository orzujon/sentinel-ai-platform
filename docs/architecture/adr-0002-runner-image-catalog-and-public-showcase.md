> Public documentation uses fictional sample values only. Real inventory resides in a private configuration repository.

# ADR 0002 — Management runner, approved-image catalog, and public showcase

- **Status:** Proposed for review — no execution changes
- **Depends on:** ADR 0001 (code, environment YAML, secrets separated)

## Decision proposed

### 1. Initial execution plane — Windows + WSL, no extra VM required

The Windows host is the trusted management plane. PowerShell orchestrates Hyper-V and host preflight; WSL runs Linux image tooling and later Ansible. The operator authenticates to the private config repository using a least-privilege **read-only** identity. Fetch an immutable Git revision and parse YAML as data, never execute it as code.

1. Read approved source-code SHA and private YAML config commit SHA.
2. Validate YAML against published schema, and compare against a policy that config editors cannot override.
3. Resolve image reference through a separate, trusted approved-image catalog.
4. Generate a read-only plan and an immutable plan digest; **no secret retrieval or VM mutation in a plan**.
5. Require explicit operator approval **of that plan digest** for apply.
6. During apply, resolve narrowly scoped secrets only if required, using short-lived credentials where supported; create limited-lifetime runtime files with restrictive ACLs, avoid leaking values into logs, CLI arguments or Git, and clean up. Current SSH public-key provisioning needs no remote private-key fetch.
7. Provision and verify with real SSH authentication, expected hostname, cloud-init completion, sudo and fixed VM memory. Report non-sensitive evidence (code SHA, config SHA, image digest, plan digest, outcome, timestamp).

Admin privileges are required for specific Hyper-V operations but should not be used for every download, test or repository read. Long-term: move this same runner interface to a separate, hardened management server/VM **outside the disposable workload VMs**. Do not attach a privileged self-hosted runner directly to public PR workflows.

### 2. Image trust and reuse are separate from deployment approval

An approved image is a **digest-bound artifact** in a trusted catalog, not just an image URL the environment config is allowed to invent.

- Today: local Stage 2 content-addressed cache (`C:\ExampleLab\Images`) stores approved Ubuntu binaries; preserve it. Introduce a read-only approved catalog (signed artifact metadata or repository with independently enforced protected approval). An image is **not approved solely because it exists on disk or because a config editor labels it approved**.
- For each image, record: logical ID, vendor, version/build date, architecture/format, upstream URL, SHA256, upstream-signature validation evidence, approval date/authority, state (candidate/approved/deprecated/revoked), and published artifact location.
- Only `approved` image digests can be resolved by `apply`; fail closed for candidate, revoked, missing or digest-mismatched artifacts. An environmental YAML value such as `imageRef: ubuntu-26.04-20261016` cannot itself grant approval.
- Store **image consumption history** in an append-only execution audit (run ID, environment, host, VM ID, image digest, timestamp). The catalog tracks allowed images; the execution audit tracks actual usage. Do not put sensitive machine inventories into the public repo.
- Future: managed storage/object store for large VHDX/qcow2 image blobs; **Harbor + ORAS** can distribute arbitrary OCI artifacts, including carefully typed VM image blobs, alongside container images. This does not make a VM image a Docker image. Use signed OCI artifact metadata and independent release gates. HashiCorp Packer can build golden images and export a manifest.

### 3. Two independent approvals

**Image approval:** Verify publisher identity/checksum and approve immutable image digest (typically once per digest until expiration or revocation). This lets all authorised environments reuse the same trusted binary.

**Deployment approval:** Approve a particular immutable code SHA + config SHA + image digest + plan digest before *each privileged apply*. No CI run triggered by an untrusted public pull request may provision Hyper-V VMs.

### 4. Vault future, and high availability reality

- For now: no Vault dependency is needed to provision with a user's **public** SSH key. Store the operator's private key locally and never upload it to Git.
- Future: learn HashiCorp Vault and compare CyberArk/BeyondTrust/managed cloud secret managers based on identity integrations, policy, operations and recovery; do not claim a particular technology is the exclusive firm-wide standard at JPMorgan Chase without evidence.
- A **two-voting-node Vault Raft cluster cannot tolerate one node failure** (quorum = 2). Use a three-node learning HA cluster when we have independent failure domains; five nodes are commonly recommended for greater production resilience. Even multiple Vault VMs on one physical PC do not protect against a host outage.
- Backups/snapshots, encryption/unseal recovery and a tested disaster-recovery procedure are required beyond merely having several Vault nodes. Enterprise multi-site DR replication is a separate future evaluation.
- Public JPMC recruiting material mentions HashiCorp, CyberArk and BeyondTrust; HashiCorp references JPMorgan use of its infrastructure products, but those sources do **not** prove a complete bank-wide secret-management topology.

### 5. Keep the source repository public as a portfolio

- Public `sentinel-ai-platform`: modules, schemas, pipelines, docs, architecture decisions, policy tests, synthetic fixtures, sanitized `lab.example.yaml`, and published **non-sensitive** demo evidence.
- Private `<private-config-repository>`: real per-environment addresses, host paths, machine sizes, secret **references**, config change history. No actual secret values in Git.
- Separate protected catalog and artifact storage: approved images and immutable digests. Consider whether operational approvals should remain private; code contains its *schema*, not production image inventory.
- Secret manager: actual secret values, identity and rotation.
- Never rely on log redaction as permission to commit a secret. Prevent secret values entering version control in the first place, then layer secret scanning and output redaction.

## Proposed immediate implementation order

1. Fix PR #1 baseline blockers (missing `lab.json` fixture for static/contract tests; stale README and stage graph); keep it in draft until validated.
2. Add non-executable public YAML **example** + schema and synthetic CI tests.
3. Add a read-only resolver for a pinned config revision and a signed/independently controlled image catalog; demonstrate `plan` does no provisioning.
4. Wire policy and plan/apply approval gates into the existing modules.
5. Run a **new** isolated end-to-end provisioning regression with SSH/cloud-init/RAM validation, leaving existing VMs alone.
6. Later introduce image registry/golden builds, Vault, separate management server, HA and DR.

## Source references (public)

- GitHub self-hosted runner security: https://docs.github.com/en/actions/reference/security/secure-use
- HashiCorp Vault Raft quorum: https://developer.hashicorp.com/vault/docs/internals/integrated-storage
- Harbor signing: https://goharbor.io/docs/main/working-with-projects/working-with-images/sign-images/
- ORAS arbitrary artifact distribution: https://oras.land/docs/how_to_guides/pushing_and_pulling/
- Packer artifact manifest: https://developer.hashicorp.com/packer/docs/post-processors/manifest
- JPMorgan Chase PAM job description: https://jpmc.fa.oraclecloud.com/hcmUI/CandidateExperience/en/sites/CX_1001/job/210768340/
