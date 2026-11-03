# JPMorgan Chase platform engineering: public evidence scan (3 November 2026)

**Research standard:** Public first-party employer sources. These are individual team descriptions, **not** a verified inventory or a claim that all JPMC teams share the same stack. Job postings can be removed or revised. Distinguish explicit evidence from suggested Sentinel design choices.

| Source | First-party fact stated publicly | Implication for Sentinel | Caveat |
| --- | --- | --- | --- |
| [Senior Lead Infrastructure Engineer – Hyper-V & VMware VCF, 210794576](https://jpmc.fa.oraclecloud.com/hcmUI/CandidateExperience/en/sites/CX_1002/job/210794576), posted 1 Oct 2026 | Compute Platform Engineering supports global Hyper-V and VMware VCF estates; automates VM provisioning, patching, compliance, retirement, performance validation; values audited AI-assisted analysis | Demonstrate full VM lifecycle + host/storage benchmarks + traced approvals, not merely Kubernetes | Doesn't identify an exclusive provisioning product |
| [Senior Lead Hyper-V Infrastructure, 210793646](https://jpmc.fa.oraclecloud.com/hcmUI/CandidateExperience/en/sites/CX_1001/job/210793646), posted 2 Oct 2026 | Custom C#/.NET 8 workload-management platform; Hyper-V, WSFC, S2D, live migration, DSC and PowerShell | A versioned internal self-service API/control plane is credible, alongside vendor-specific adapters | Custom code remains proprietary; no internals publicly documented |
| [Lead Platform Engineer – Cloud Foundry & Kubernetes, 210800125](https://jpmc.fa.oraclecloud.com/hcmUI/CandidateExperience/en/sites/CX_1002/job/210800125), posted 22 Oct 2026 | Concourse, BOSH, Cloud Foundry, Terraform, Kubernetes; modernization of foundation upgrades and teardown | Concourse pipelines and immutable infrastructure change workflows are directly career-relevant | Concourse usage established for this team, not the entire bank |
| [Lead Infrastructure Engineer – Linux & VMware, 210781140](https://jpmc.fa.oraclecloud.com/hcmUI/CandidateExperience/en/sites/CX_1001/job/210781140) | VMware, OpenShift, Terraform, Ansible, Shell and operational monitoring | Add policy/pipeline-managed Linux guest lifecycle and app cluster deployment | Requirements may combine skills not used in one pipeline |
| [Senior Principal Architect – HW Performance, 210782001](https://jpmc.fa.oraclecloud.com/hcmUI/CandidateExperience/en/sites/CX_1001/job/210782001) | Bare-metal, VMware/KVM/Hyper-V, full VM lifecycle, Kubernetes/OpenShift, multi-tenancy and virtual networking | Architecture should correlate physical, VM, network and cluster layers | Large-scale skills cannot be credibly claimed from a single-host lab |
| [JPMorganChase engineering platform article](https://www.jpmorganchase.com/about/technology/blog/our-commitment-to-the-engineer-experience) | JPMC publicly discusses its internal developer experience and self-service/platform engineering | Offer service catalog, repeatability, governance, discoverability and trouble-shooting experience | Confirm exact publication and numerical claims against the article before quoting in public-facing portfolio |

## Findings

1. **Multiple control planes exist.** At least some teams advertise VMware VCF, Hyper-V, OpenShift Virtualization, and Cloud Foundry/BOSH; there is no public evidence for one exclusive JPMC hypervisor or CI/CD system.
2. **They hire for controlled VM lifecycle and engineering workflows.** Provisioning is only one stage: patch, benchmark, validate, monitor, govern, retire and record evidence.
3. **Software abstractions matter.** The advertised custom Hyper-V workload-management platform validates a control-plane/application layer above vendor APIs, while proving nothing about its exact implementation.
4. **Concourse is a strong relevant choice.** The October 22 vacancy explicitly calls it out, along with BOSH and Terraform.
5. **Avoid an imitation claim.** Sentinel Fabric is an independent, source-informed architectural project, not a JPMorgan Chase implementation or endorsed reproduction.

## Public verification and dated scope

Research conducted 3 November 2026 using live public job advertisements; job IDs and posting dates taken from individual advertisements. Use the job IDs and archived research summaries if a listing later disappears. None of these sources are technical deployment diagrams, complete procurement records, software bills of materials, or guarantees about firm-wide production usage.

**Decision:** [Sentinel Fabric RFC](../architecture/rfc-0003-sentinel-fabric.md) uses the same general engineering competencies with inexpensive KVM/libvirt, OpenTofu, cloud-init, Ansible, Concourse and an API/portal; no enterprise vendor license or misleading HA claim.
