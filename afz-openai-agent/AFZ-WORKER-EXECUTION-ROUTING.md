# AFZ worker execution routing policy

**Status:** ACTIVE / GLOBAL ADDENDUM  
**Parent policy:** `AFZ-GITHUB-FIRST-ALL-PROJECTS.md`  
**Effective:** 2026-08-28

This policy governs where AFZ executable jobs run. It does not create a second scheduler or replace Control Hub/PostgreSQL/Direct Fabric authority.

## Queue semantics

An AFZ execution queue is for **executable jobs/claims only**. It is not a project-status, handoff, coordination, source-sync, or result-archive mechanism.

GitHub remains the durable source/coordination/result plane. Control Hub/PostgreSQL/Direct Fabric remains the live execution/lease/health/routing authority. OneDrive/SharePoint remains emergency fallback only and must not become the normal queue or result transport.

## Default routing rule

Executable scripts are **portable by default** when their requirements can be satisfied by more than one worker.

Default job intent:

- `workerAffinity = auto`
- `portable = true`
- select the first healthy compatible worker from the active pool using current Direct Fabric/Control Hub state
- do not pin a job to Windows-main merely because Windows-main submitted, generated, or previously ran it
- if a selected worker becomes unavailable before claim/execution, another compatible worker may claim the job

Compatible workers include Windows-main/ASUS, H3, Lenovo, and the Windows HP laptop for Windows/PowerShell work, plus HP Envy and Pi for Linux-compatible work when capabilities and data locality permit.

## Explicit affinity exceptions

Pin a job only when a real execution dependency requires it. Valid examples include:

- physical USB/ADB device attached to one host
- machine-local hardware or peripheral
- machine-local credential/key that must not be copied
- service/process that is owned locally by one host
- non-portable local data or filesystem state
- OS-specific requirement
- GPU/model/runtime requirement
- elevated context available only on a specific worker

Affinity must describe the dependency, not just a preferred machine name.

Example: the current FamilyPTT development bridge recovery is `localHardware=windows-main` because the Pixel is physically USB-attached to ASUS and the ADB reverse mappings plus local bridge ports live there. FamilyPTT source inspection, builds, parsing, audits, and other portable scripts should remain `workerAffinity=auto` unless another concrete dependency applies.

## Worker selection

For portable jobs, route dynamically using, in order:

1. required OS/tool/runtime capability;
2. fresh health/readiness state;
3. CPU/RAM/GPU pressure and available execution slots;
4. data locality and transfer cost;
5. existing project/service ownership when it materially reduces risk;
6. wake/warm-up cost when an appropriate sleeping worker can be safely activated.

Do not use a stale file-sync heartbeat as the sole authority for worker eligibility.

## No sticky queueing

A portable script must not sit behind unrelated work merely because it was written into one worker's private queue. The dispatcher should keep the job portable until it is claimed. Worker-specific queues are appropriate only after a claim or when explicit affinity is required.

Do not duplicate a portable job into multiple worker queues. One claim/lease remains authoritative to prevent dual execution.

## Result path

Runtime result state returns through the active Direct Fabric/typed execution path. Material, sanitized result summaries are reconciled into the canonical GitHub project thread. Do not use OneDrive/SharePoint as normal result ingress.

## Emergency fallback

If the direct/GitHub execution bridge is unavailable, an explicitly declared `EMERGENCY_FALLBACK` may use the legacy worker execution queue for a bounded script. The job must retain its portability/affinity metadata conceptually, and material results must be reconciled back into GitHub. Emergency fallback must not silently become the normal transport.
