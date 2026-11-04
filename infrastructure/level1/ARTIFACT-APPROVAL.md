# Fresh-cluster artifact review and provenance evidence

**Status:** evidence verification only; no artifact approval or deployment permission
is granted by this document or by the tool. Preserve the existing fresh cluster.
Do not run BOOTSTRAP against occupied fresh nodes.

## Approved-source candidates under review

The pending profile is \`sentinel-fresh-cluster-v1\` in
\`config/fresh-artifacts.lock.json\`. Ubuntu image build 20261016 has
SHA256 \`5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5\`.
Flannel is \`v0.28.10\` with upstream manifest SHA256
\`393bdbce53eb50c8eb97dd513b218518b7d6e7985dc7b889be956e112a711084\`.

The historical image catalog record is **candidate** with
\`deploymentPermitted=false\`; past signature verification was only
operator-reported. The new lock is **pending-review**. Neither PR CI passing nor
a successful image-cache hash check changes those facts.

The canonical signing key fingerprint for Ubuntu cloud images, confirmed by
Canonical documentation, is:

\`D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81\`

Primary source: https://ubuntu.com/docs/public-images/public-images-how-to/verify-image-checksum/

## First: collect fresh evidence (read-only; operator-run)

From the **primary local checkout** of the evidence PR:

\`\`\`powershell
cd C:\Users\Orzu\projects\sentinel-ai-platform
git status --short
git rev-parse HEAD
wsl.exe -d Ubuntu-26.04 --exec python3 /mnt/c/Users/Orzu/projects/sentinel-ai-platform/infrastructure/level1/tools/verify_fresh_artifact_evidence.py
\`\`\`

The verifier requires a clean checkout. It reads the exact Git-tracked lock,
rechecks the SHA256-named Windows Stage2 cached image and sidecar, retrieves
Canonical's HTTPS \`SHA256SUMS\` and \`SHA256SUMS.gpg\`, imports a public
key only into an ephemeral GPG home, checks the **full pinned primary-key
fingerprint**, runs \`gpgv\`, compares the signed manifest entry to the
locked and locally hashed image, and downloads/re-hashes the exact Flannel
release YAML. It writes a private JSON attestation with the exact Git commit,
lock SHA, SHA256SUMS/SHA256SUMS.gpg digests, signing fingerprint, image digest
and Flannel digest.

The verifier uses network **only for retrieval of read-only verification
material** (checksum metadata, signature and public key) and the pinned
Flannel manifest. It never updates cache, changes VM state, registers SSH
trust or deploys to Kubernetes. It uses installed \`python3\`, \`git\`,
\`gpg\` and \`gpgv\` in Ubuntu WSL. Missing tools/network access cause a
block, not a bypass. Diagnostic failures should be investigated, **not**
fixed by recalculating a new approved hash from an arbitrary file.

On success:

\`\`\`text
FRESH_ARTIFACT_PROVENANCE_PASS: Canonical signature, signed image SHA256, local image and upstream Flannel SHA256 verified
FRESH_ARTIFACT_PROVENANCE_AUDIT: /home/.../.local/state/sentinel-fresh/attestations/....json
FRESH_ARTIFACT_APPROVAL: PENDING human review; this does not authorize BOOTSTRAP
\`\`\`

Private audit stays in WSL, mode 0600. Share only the PASS/BLOCKED summary
and non-sensitive metadata for discussion; keep any internal/private audit
data out of GitHub until reviewed and sanitized.

## Second: authorization and promotion (not automated)

1. Independently review signer identity/fingerprint against Canonical's
   published source; confirm the image digest from the signed checksum,
   local image/sidecar, exact lock digest, branch and Git commit.
2. Independently review Flannel upstream version, reviewed manifest SHA,
   rendered manifest policy and whether its *unsigned* release provenance
   is acceptable for this lab. The Flannel verifier guarantees content matches
   a reviewed digest; **it does not verify a publisher signature**.
3. Confirm the code branch CI and human security review, including changes to
   the lock/verification script and the provenance tool itself.
4. Record a real approver identity, review date, exact source Git commit,
   approved artifact lock SHA, evidence hash/location and security exceptions.
   A self-authored JSON \`approved\` field alone is **not** independent
   authorization. A repository maintainer must configure and verify GitHub
   branch protection (required reviews/status checks, no bypass as appropriate)
   if separation of duties is claimed. An individually operated lab can
   document a *single-operator acceptance*, but **must not claim independent
   two-person approval**.
5. After review, propose a separate promotion PR changing the lock's
   \`review.status\` and attribution with a documented review decision,
   and merge only when the branch protection / human-review requirements
   are satisfied. No script should promote a candidate merely because a
   checksum matches. Observe the local profile revision after pulling.
6. Only for a **new, unoccupied** isolated test profile, with a passing host
   capacity/collision PLAN, separately obtain the operator's explicit
   execution approval. No approval here authorizes BOOTSTRAP on the
   existing \`sentinel-fresh-cp01/w01\` pair.

Future enforcement work: strengthen the runtime approval gate so that it
verifies an independently authenticated and protected approval artifact
rather than trusting only the JSON status and review attribution. Until
implemented, a local status change alone must not be treated as an
independent review. Also bind an aggregate end-to-end acceptance report
to a single immutable code revision and stage results.
