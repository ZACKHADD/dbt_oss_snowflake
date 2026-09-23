---
name: production-dbt-snowflake-cicd
description: Design and implement a production-grade GitHub CI/CD pipeline for a dbt + Snowflake project with four environments, developer-isolated development objects, Slim CI, Airflow on Kubernetes via Argo CD GitOps, Terraform-managed infrastructure, decoupled release cuts, QA/UAT-separated approvals, and tag-based production deployments.
---

# Production dbt Snowflake GitHub CI/CD

## Objective

Design and implement a production-grade GitHub CI/CD process for a dbt + Snowflake project.

The solution must provide:

* GitHub-based CI/CD.
* Two main Git branches:

  * `develop`
  * `main`
* Four deployment environments:

  * `dev`
  * `rct`
  * `ppd`
  * `prd`
* dbt Slim CI in all shared environments.
* Developer-isolated Snowflake objects for feature development, deployed **locally by the developer**, not by push-triggered CI.
* Automated SQL compilation and linting on every push.
* Real dbt build + test execution gated at **PR** stage, not at every push.
* Automated Snowflake deployments, decoupled from Git merges except where explicitly specified.
* Airflow deployment on Kubernetes via **Argo CD GitOps**, never a direct branch-head sync.
* QA-controlled promotion into RCT, **decoupled from `develop` merges** — triggered only by a deliberate release cut.
* Business/UAT-controlled promotion into production, as a **separate gate from QA**.
* Versioned releases cut as real branches (a "screenshot" of `develop`), supporting fix-forward and partial-release handling.
* Git tags used as immutable production deployment references, created only after RCT+PPD+UAT validation.
* Terraform-managed Snowflake schemas and higher-level infrastructure, with a one-time-provisioned developer sandbox boundary.
* Clear separation between infrastructure provisioning and dbt object deployment.

The implementation should favor reproducibility, traceability, isolation, fast CI execution, and safe promotion between environments.

---

# Target Git Strategy

Use the following branching model:

```text
feature/*
    |
    | Pull Request
    v
develop
    |
    | Release cut (deliberate, not automatic)
    v
release/*
    |
    | Pull Request (after RCT + PPD + UAT validation)
    v
main
    |
    | Tag
    v
production
```

## Branches

### Feature branches

Developers work on:

```text
feature/<developer>/<feature-name>
```

A feature branch must never deploy directly to shared environments, and — per the decision made in this project — **must not deploy anywhere via CI at all**. Deployment of a developer's isolated objects happens only through the developer's own local `dbt build --target developer`.

A push to a feature branch triggers:

1. SQL/dbt linting.
2. dbt parsing/compilation.

That is the entire push-triggered pipeline. No Snowflake credentials are involved in this job, and no dbt build/test/deploy runs on push. This is an explicit trade-off:

* **Gain:** no Snowflake credentials distributed to every push-triggered CI job; fast, free feedback (seconds, no warehouse compute) on every commit.
* **Cost:** lint/parse/compile catches syntax and DAG issues only — it does **not** prove the code runs, that tests pass, or that permissions are correct. The real "fail fast" gate moves to PR time (see below). Document this explicitly for developers: a green push check means "well-formed," not "will build."

The developer tests locally before opening a PR:

```bash
export DBT_DEVELOPER_NAME=alice
dbt build --target developer
```

which deploys into their isolated schema.

---

### `develop`

`develop` represents the shared development integration environment.

A Pull Request from:

```text
feature/* -> develop
```

must execute CI validation — and this is where the **real** build + test execution happens (see "Pull Request: Feature -> Develop" below), since push-stage no longer does it.

After the PR is merged, the pipeline deploys the dbt changes to the shared `dev` environment. This is a **continuous** deployment — every merge to `develop` triggers a `dev` deploy.

The shared `dev` environment is used by the development team and must not contain developer-specific naming.

Example:

```text
DEV_DATABASE
    |
    +-- ANALYTICS
        |
        +-- customer
        +-- orders
        +-- payments
```

**Critical invariant — merging to `develop` does NOT cascade to RCT or PPD.** RCT and PPD are not continuously deployed. They are only updated by a deliberate, separately-triggered **release cut** (see "Release Process" below). Cascading every `develop` merge through RCT would constantly disturb the QA environment with incoherent, half-batched changes and defeats the purpose of having a stabilization environment. `develop` deploys to `dev`, full stop; nothing downstream moves until someone explicitly cuts a release.

---

### `main`

`main` represents production-ready code.

Production deployment must only originate from a versioned release merged into `main`.

**Merge-then-deploy is inverted on this branch compared to `feature -> develop`.** For `release/* -> main`, deployment and validation happen *before* the merge, not after:

```text
1. Cut release/vX.Y.Z from develop @ commit SHA   (the "screenshot")
2. Deploy that exact SHA to RCT   — QA approval   — validate
3. Deploy that same SHA to PPD    — UAT approval  — validate
4. Only now: open/approve the release PR -> main
5. Merge into main
6. Tag main as vX.Y.Z              (tag is immutable AND already proven)
7. Deploy tag vX.Y.Z to PRD Snowflake + PRD Airflow
```

`main` must never contain code that has not already been fully validated in RCT and PPD/UAT. Merging into `main` before validation would let a failed RCT/UAT run pollute `main` with unvalidated code requiring a revert — the merge is the *last* gate, not an early one.

Production deployment must reference an immutable Git tag.

Example:

```text
v1.8.0
```

Airflow production should point to the exact Git tag used for the production deployment.

Snowflake production should also be deployed from that same immutable version.

---

# Environment Model

The project contains four environments:

| Environment | Snowflake          | Airflow             | Purpose                        | Promotion trigger |
| ----------- | ------------------- | -------------------- | ------------------------------- | ------------------ |
| `dev`       | Shared development  | Development Airflow  | Integration development         | Every `develop` merge (continuous) |
| `rct`       | RCT                  | RCT Airflow           | QA functional validation        | Explicit release cut, QA-gated |
| `ppd`       | PPD                  | PPD Airflow           | Business/UAT acceptance         | RCT sign-off, UAT-gated |
| `prd`       | Production            | Production Airflow    | Production                      | PPD + UAT sign-off, tag-based |

Each environment must have independent configuration and credentials.

Environment-specific configuration must never be hard-coded into dbt models.

**QA and UAT are two separate, sequential gates, never blended into one approval:**

| Gate | Who | Validates | Blocks |
|---|---|---|---|
| **QA sign-off** | QA team | Functional correctness (build succeeds, tests pass, numbers are right) | Promotion RCT -> PPD |
| **UAT sign-off** | Business/product owners | Business acceptance (this is what was asked for, works for the business workflow) | The `release/* -> main` PR, i.e. promotion PPD -> prd |

These must be modeled as **two distinct required-reviewer groups on two distinct GitHub Environments/gates** (`rct` environment -> QA group; `main`/`prd` environment or the release PR itself -> UAT/business-owner group), not a single combined checkbox. QA finishing does not imply the release is ready for prod — it only unlocks PPD.

---

# Infrastructure Ownership

Terraform owns infrastructure and persistent higher-level Snowflake objects.

Terraform should be responsible for objects such as:

* Databases.
* Schemas (shared/environment schemas — **not** per-developer schemas, see below).
* Roles.
* Grants.
* Warehouses.
* Integrations.
* External stages.
* Other infrastructure-level Snowflake resources.

dbt owns objects generated by dbt, such as:

* Tables.
* Views.
* Incremental models.
* Dynamic tables, if applicable.
* Tests.
* dbt-managed schemas/objects where appropriate, including per-developer schemas (see below).

Do not use the CI/CD pipeline to recreate infrastructure that is already managed by Terraform.

---

# Feature Branch Workflow

When a developer pushes to a feature branch:

```text
feature/alice/customer-model
```

the GitHub pipeline should execute:

```text
1. Checkout source
2. Install dependencies
3. Validate project configuration
4. SQL lint
5. dbt parse
6. dbt compile
7. Report result
```

That's it — **no deployment step on push.** No Snowflake credentials are resolved in this job.

The developer deploys and tests their changes locally, in Snowflake, without touching any shared environment:

```bash
export DBT_DEVELOPER_NAME=alice
dbt build --target developer
```

---

# Developer-Specific Snowflake Environment

Developer environments are different from the four shared environments.

The goal is to provide each developer with isolated dbt-generated objects.

## Decision: schema-per-developer, not object-suffix

**Use schema-per-developer** (`ANALYTICS_ALICE`), not object-level suffixes (`customer_alice`). Rationale:

* Snowflake grants are schema-scoped. Object-suffix isolation inside one shared schema means either per-object grants (hard to automate correctly) or no real isolation — any role with schema usage can see/drop other developers' objects.
* Schema-per-developer gives real isolation (grant the developer role `OWNERSHIP`/`ALL` on just their own schema), trivial cleanup (`DROP SCHEMA`), and clean `SHOW OBJECTS IN SCHEMA` auditability.
* Object-level prefixes are the fallback **only** if the Snowflake edition/role model genuinely cannot support dynamic per-developer schema creation.

```text
developer = alice
target = dev_alice
schema = analytics_alice
```

Generated objects:

```text
ANALYTICS_ALICE.customer
ANALYTICS_ALICE.orders
ANALYTICS_ALICE.payments
```

## Resolving the "Terraform owns schemas" tension

Per-developer schemas must **not** require a Terraform apply per developer (that turns onboarding into an infra PR). Resolve this by splitting what Terraform owns into a one-time boundary vs. a per-developer object:

* **Terraform provisions, once:** a `DEV_SANDBOX` database, a `DEVELOPER` role, a warehouse, and a grant giving the `DEVELOPER` role `CREATE SCHEMA` **scoped only inside `DEV_SANDBOX`** — nothing else. No Terraform change is needed to onboard a new developer; they're simply added to the `DEVELOPER` role.
* **dbt creates the per-developer schema at build time** (native `create schema if not exists` behavior via `generate_schema_name`), computing `analytics_<developer>` from `DBT_DEVELOPER_NAME`.
* Terraform still owns the *boundary that matters* (the sandbox database, the role, the privilege envelope) without owning each individual schema.
* **A scheduled cleanup job is mandatory, not optional**, precisely because nothing in CI touches developer schemas anymore (deployment moved local-only) — there is no automatic signal when a schema goes stale. Run a nightly/weekly GitHub Action or Snowflake task that drops developer schemas whose feature branch has been merged/deleted, or that haven't been touched in N days.
* CI service accounts never need `CREATE SCHEMA` rights inside the sandbox at all — only individual developers' personal, key-pair-authenticated Snowflake credentials do, scoped to their own schema only.

---

# Developer dbt Target

Create a dedicated dbt target for local developer execution.

Example:

```yaml
targets:
  dev:
    schema: analytics

  developer:
    schema: analytics_<developer>
```

The exact implementation must avoid hard-coding the developer name.

The developer name should be supplied through an environment variable, GitHub variable, or local configuration.

For example:

```bash
export DBT_DEVELOPER_NAME=alice
```

Then dbt should resolve:

```text
analytics_alice
```

as the target schema. In PR-stage CI (see below), the same variable is derived automatically from the PR author's GitHub username rather than set manually.

---

# Local Developer Commands

Developers should be able to run dbt locally using a developer-specific target.

Example:

```bash
dbt build --target developer
```

or:

```bash
dbt build --select <model> --target developer
```

The implementation should provide convenient commands such as:

```bash
make dbt-dev
make dbt-build MODEL=customer
make dbt-test MODEL=customer
```

The exact commands should be documented.

The developer must never accidentally run local commands against shared `dev`, `rct`, `ppd`, or `prd`.

Production and shared environment credentials should not be available through normal developer local profiles. Add a CI **and** local guard: assert the resolved target schema starts with `analytics_<developer>` before any `dbt build` runs against the `developer` target, and fail hard if not — this protects against a misconfigured `DBT_DEVELOPER_NAME` accidentally resolving to a shared schema.

---

# Developer Object Naming

The implementation must define one consistent naming strategy.

Preferred approach:

```text
<developer_schema>.<dbt_object>
```

Example:

```text
ANALYTICS_ALICE.customer
ANALYTICS_ALICE.orders
```

rather than:

```text
ANALYTICS.customer_alice
ANALYTICS.orders_alice
```

unless technical constraints require object-level prefixes.

The naming mechanism should be implemented centrally in dbt configuration rather than manually inside individual models.

Models should continue to use:

```sql
{{ ref('customer') }}
```

and should not contain developer-specific names.

---

# Slim CI

All four shared environments must use dbt Slim CI.

Do not perform unnecessary full-project builds for every deployment.

Use dbt artifacts from the previous successful deployment as the comparison state.

The pipeline should use:

```bash
dbt build --select state:modified+ --defer --state <previous-state>
```

or an equivalent selector appropriate for the project's dependency graph.

The exact selector must be validated against the project's dbt version and deployment model.

---

# Slim CI State Management

Each shared environment needs its own dbt state.

At minimum:

```text
dev state
rct state
ppd state
prd state
```

Do not use a single state artifact for all environments.

**State storage must be persistent, not just GitHub Actions artifacts.** GitHub Actions artifacts expire (90-day default) and are not a system of record. Store `manifest.json` / `run_results.json` per environment in a durable location (cloud storage bucket, or a Snowflake internal stage) keyed by environment + commit SHA, with a "latest successful" pointer updated only after a green deploy.

Example artifact structure:

```text
dbt-state/
    dev/
    rct/
    ppd/
    prd/
```

Each successful deployment should publish the dbt artifacts required for the next Slim CI run.

Relevant artifacts include:

```text
manifest.json
run_results.json
catalog.json
```

where applicable.

The pipeline must guarantee that the state used for an environment represents the last successfully deployed version of that environment.

## Cold-start (first-ever) Slim CI run

On an environment with **no published state yet**, `--state <dir>` has no manifest and `state:modified+` is meaningless. Bootstrap the baseline deterministically instead of guessing:

```bash
# step 1: full build, no state reference
dbt build --select "+all_seeders +"   # or simply: dbt build (config-driven)
# step 2: publish state only if the entire run is green
# step 3: future runs switch to the normal state:modified+ selector
```

Treat a successful bootstrap as identical to a successful deploy: publish `manifest.json`/`run_results.json` to the durable store with a "latest successful" pointer, and set an `IS_BOOTSTRAPPED` per-environment flag that gates the Slim CI path. Until bootstrapped, deploy workflows must run the bootstrap path — never a `state:` selector against an empty state directory, which silently degrades.

## Empty-selection guard (the "false green" Slim CI)

`dbt build --select state:modified+` **exits 0 when the selection matches zero nodes** — the pipeline reports green without verifying anything. That is an acceptable *no-op* only when it is explicit:

* Fail the job **if the selectors produce an ambiguous/zero result for a reason other than "no difference vs the reference state"** — differentiate `selected=0 because no changes since last published state` from `selected=0 because the classifier/selector itself is broken`.
* Log `dbt ls --select state:modified+ --state <dir>` output explicitly in the workflow so an empty run is self-explanatory.
* Do **not** report "deployed N models" when N=0; label it `NO-OP: no modified nodes vs <env> state @ <SHA>`.
* Never let tag-triggered or UAT-gated prod paths short-circuit on selection: for PRD, a zero-diff is still gated and must produce an audit record, not just exit 0.

## Deleted / removed models are not dropped by Slim CI

`--select state:modified+` computes what to *build*, never what to *drop*. A model that disappears from `models/` between two releases stays in Snowflake as an orphan — this is the same class of problem as the RCT-quarantine orphan (see "Handling a partial QA failure").

* Add an explicit **removed-node drop job** to every shared-environment deploy (`dev`/`rct`/`ppd`/`prd`): diff the new manifest against the environment's previous manifest and `DROP TABLE/VIEW IF EXISTS` (or `dbt run-operation`) for `added:no` `deleted:yes` nodes — scoped to that environment's schema, never `ANALYTICS_%` wildcards that could touch developer or other-env objects.
* Dry-run + audit it first in `dev`; gate `rct`/`ppd`/`prd` drops behind the same approval as the deploy.
* Symmetric rule: promotion reverts (QA/UAT rejects) must quarantine **and** reconcile the state baseline so the reverted model is not later resurrected by a stale manifest (see State Promotion Principle).

## Argo CD sync is separate from bumping the manifest ref

Updating `deploy/<env>` to a SHA/tag only records intent; a `Sync` may be `Pending`/`OutOfSync`/`Failed` for a long time. "Manifest ref bumped" is not "environment deployed."

* After every Argo manifest bump, add a **sync-health verification step** that polls the Argo CD Application until `health.status == Healthy` and `sync.status == Synced` against the exact target revision (or fails) before the workflow reports success.
* Reuse one reusable action/step for this across dev/rct/ppd/prd so the behavior is uniform.
* Log the target revision recorded *and* the revision actually running in the cluster side-by-side in deployment metadata — that is the field that lets an auditor prove Invariant 7 at runtime, not just by policy.

---

# Developer / PR-Stage Slim CI

**Decision: Option C — compare against shared `dev` state, but only run at PR time, not at push time.**

Since push-triggered CI no longer deploys (see "Feature Branch Workflow"), the real Slim CI build+test execution happens once, at PR stage, against the PR author's own developer schema:

```bash
dbt build \
  --select state:modified+ \
  --defer \
  --state dev-state/ \
  --target developer
```

Rationale for Option C over the alternatives considered:

* **Option A (local developer state)** isn't reproducible in CI — a laptop `target/` isn't available to GitHub Actions, so it only helps local runs, not the pipeline's own gate.
* **Option B (per-branch state in GitHub)** works but adds a state lifecycle to garbage-collect (stale states from abandoned/rebased branches) for a benefit that mostly matters on very large projects.
* **Option C** reuses infrastructure already needed for the `dev` state store, needs no extra cleanup job, and is sufficient since feature branches are about to merge into `develop` anyway. Unchanged upstream models resolve against `dev` via `--defer`; only actually modified models build, but they build **into the developer's own schema**, never into shared `dev`.

**Guard rail:** add a CI step that asserts the resolved target schema starts with `analytics_` + the PR-author-derived developer name before any `dbt build` runs, and fail hard if not — this is the only thing standing between a misconfigured run and an accidental write into shared `dev`.

Required decision record for this section (already resolved above, keep documented in `docs/`):

* Where state is stored: durable store keyed by environment + SHA (see Slim CI State Management).
* How state is generated: published only after a successful shared-environment deploy.
* How state is versioned: by environment name + commit SHA.
* How state is cleaned up: retention policy on the durable store; no GitHub Actions artifact reliance.
* How `--state` is selected: `dev-state/` (latest successful `dev` state) for PR-stage runs; each shared environment's own latest state for its own Slim CI.
* How `--defer` is used: always, so unchanged upstream models resolve against the reference state instead of rebuilding.
* How developer schemas are resolved: `DBT_DEVELOPER_NAME` -> `analytics_<developer>`, derived from GitHub PR author at PR-stage, from local env var for local runs.
* How branch isolation is guaranteed: build output always targets `developer`, never `dev`/`rct`/`ppd`/`prd`, enforced by the schema-prefix guard rail.

---

# Pull Request: Feature -> Develop

When a developer creates:

```text
feature/* -> develop
```

the PR pipeline must run validation before merge. **This is the actual fail-fast gate for the whole feature workflow**, since push-stage CI is lint/parse/compile only.

Minimum checks:

```text
SQL lint
dbt parse
dbt compile
dbt Slim CI build (into the PR author's developer schema, Option C state)
dbt tests (on the modified nodes)
```

The PR should expose useful information through GitHub checks.

For example:

```text
✓ SQL lint
✓ dbt parse
✓ dbt compile
✓ dbt Slim CI build
✓ dbt tests
```

**PR ergonomics:** post the Slim CI-selected model list and a compiled-SQL diff as an automated PR comment, so reviewers see exactly what will run/change without pulling the branch locally.

A PR should not be mergeable if mandatory checks fail.

---

# Merge Into Develop

After the PR is approved and merged:

```text
feature/* -> develop
```

the deployment pipeline should:

```text
1. Checkout develop
2. Resolve dev credentials
3. Retrieve previous dev dbt state
4. Determine modified nodes
5. Run dbt Slim CI
6. Apply changes to shared dev Snowflake
7. Publish new dev dbt artifacts
8. Update dev deployment state
```

The resulting Snowflake objects are shared by the development team.

Use a GitHub Actions `concurrency:` group scoped to the `dev` environment so two near-simultaneous merges cannot race to deploy against the same state and corrupt the Slim CI baseline.

---

# Dev Airflow Deployment (Argo CD GitOps)

After successful deployment to shared dev Snowflake, the dbt/DAG code is synced to the Kubernetes cluster hosting Airflow for the dev environment — via **Argo CD**, not a direct `kubectl apply` from the CI job.

**GitOps pattern:**

* DAG source lives in the app repo (or a split repo — architecture-dependent).
* A lightweight **deploy-manifest ref per environment** is what Argo CD actually watches: `deploy/dev`, `deploy/rct`, `deploy/ppd`, `deploy/prd` branches, or a per-env `kustomization.yaml`/values file pointing at a specific Git ref.
* Argo CD is **never** pointed at a raw, moving branch head (`develop`/`main`) for `rct`/`ppd`/`prd`. It only ever syncs against the deploy-manifest ref.
* The pipeline updates the deploy-manifest ref **only after** the corresponding Snowflake deployment succeeds — bumping `deploy/dev` to the just-validated SHA (or, for prod, pointing it at the release tag).

Example:

```text
develop
   |
   v
Snowflake dev deployment (succeeds)
   |
   v
Bump deploy/dev ref to this SHA
   |
   v
Argo CD syncs dev Airflow from deploy/dev
```

This is how Invariant 7 (Snowflake and Airflow for an environment must use the same Git revision) is actually guaranteed: Argo is watching a pointer that only moves after Snowflake succeeds, and it is always set to the exact SHA/tag just validated — not a branch head Argo tracks independently.

`dev`'s Argo Application can auto-sync. `rct`/`ppd`/`prd` should use an Argo CD sync window or a manual sync tied to the same approval used for the Snowflake deployment, so the two never drift out of lockstep.

---

# Release Cadence and the Release Cut

## Decoupling release cuts from sprint boundaries

`develop` deploys to `dev` continuously. **RCT and PPD are only updated by a deliberate release cut** — never by individual `develop` merges. A release cut takes a "screenshot" of `develop` at a chosen commit and promotes *that snapshot*, as a coherent batch, through RCT and PPD.

## Cutting the release ("the screenshot")

Create a real `release/vX.Y.Z` branch pinned at a specific SHA — not just a tag at this stage, because you need a mutable-but-controlled ref to absorb release-stabilization fixes over the following days without restarting the whole cut:

```bash
git checkout develop
git pull origin develop
RELEASE_SHA=$(git rev-parse HEAD)

git checkout -b release/v1.7.0 $RELEASE_SHA
git push origin release/v1.7.0
```

Trigger this via a `workflow_dispatch` workflow (`cut-release.yml`) run by the Release Manager, not automatically on every `develop` merge:

```yaml
name: cut-release
on:
  workflow_dispatch:
    inputs:
      version:
        description: "Release version, e.g. v1.7.0"
        required: true

jobs:
  cut:
    runs-on: ubuntu-latest
    environment: release
    steps:
      - uses: actions/checkout@v4
        with:
          ref: develop
          fetch-depth: 0
      - name: Record snapshot SHA
        run: echo "SHA=$(git rev-parse HEAD)" >> $GITHUB_ENV
      - name: Create release branch
        run: |
          git checkout -b release/${{ inputs.version }} ${{ env.SHA }}
          git push origin release/${{ inputs.version }}
      - name: Create draft GitHub Release
        run: |
          gh release create ${{ inputs.version }} \
            --target release/${{ inputs.version }} \
            --title "${{ inputs.version }}" \
            --generate-notes \
            --draft
        env:
          GH_TOKEN: ${{ github.token }}
```

Do **not** create the immutable Git tag at this point — only after RCT + PPD + UAT validation and the merge into `main` (see "Release -> Main").

Pushing `release/vX.Y.Z` triggers the RCT deploy workflow.

Optional: adopt `release-please`/`semantic-release`-style tooling to compute the version number deterministically from conventional commits — but keep the *timing* of the cut a human (Release Manager) decision via `workflow_dispatch`, since batching multiple merges into one considered release is usually preferable to releasing every commit automatically.

## Recommended sprint timing (2-week sprint)

```text
Week 1                                  Week 2
Mon  Tue  Wed  Thu  Fri     Mon  Tue  Wed  Thu  Fri
D1   D2   D3   D4   D5      D6   D7   D8   D9   D10
                             ^
                    Release cut here (~D7, 60-70% through sprint)
```

Cut the release **mid-to-late in week 2, not on the last day.** Cutting on D10 leaves no runway for RCT triage, PPD, and UAT — which is exactly what produces "QA passed but UAT hasn't finished by end of sprint." Cutting around D7 leaves 2-3 working days inside the sprint for a fix-and-retest cycle, and normalizes that the production deployment date can land in the first day or two of the *next* sprint without that being treated as an incident. **Production date and sprint boundary are not the same thing and must not be forced to coincide.**

---

# RCT Promotion

After a release cut, the code is promoted to RCT. This is triggered by the release-branch push, not by any `develop` merge.

The RCT promotion must require QA approval.

Workflow:

```text
release/vX.Y.Z
 |
 v
rct Snowflake  -- Slim CI --
 |
 | QA approval
 v
rct Airflow (Argo CD sync, gated on Snowflake success)
```

The Snowflake deployment must:

```text
1. Retrieve previous RCT state
2. Calculate modified dbt nodes
3. Run dbt Slim CI
4. Deploy changes to RCT Snowflake
5. Publish new RCT state (only if the whole run succeeds)
```

After successful Snowflake validation and QA approval, deploy the same revision to RCT Airflow via the Argo CD manifest bump described above.

## Handling a partial QA failure within a multi-feature release cut

A release cut can contain multiple features from multiple developers. If QA approves some and rejects others, **do not hold the whole release hostage.** Because the release cut is a real branch, remove the failing feature from *this* release without touching `develop` or the passing feature:

```bash
git checkout release/v1.7.0
git log --oneline               # find the failing feature's merge commit, e.g. b0bfeaa

git revert -m 1 b0bfeaa --no-edit
git push origin release/v1.7.0
```

This re-triggers the RCT deploy workflow. Two things require explicit handling, not just relying on Slim CI's diffing:

1. **State comparison after the revert.** Slim CI compares against RCT's last *published* state, which included the now-reverted model. Since the model file is back to its pre-change form, `state:modified+` will correctly skip rebuilding it going forward — but:
2. **Orphaned objects from the earlier (successful build, later QA-rejected) run do not disappear automatically.** Slim CI decides what to *build*, not what to *drop*. Add an explicit quarantine/cleanup step in the revert-triggered redeploy:
   ```bash
   scripts/quarantine_model.sh analytics.orders_fulfillment
   # e.g. a thin wrapper around DROP TABLE IF EXISTS / dbt run-operation
   ```
   Have this script ready ahead of time rather than improvising it during a live release.

After the redeploy, QA does a scoped re-check (not a full re-test) of only what changed, and signs off. The rejected feature stays on `develop`, untouched, and rides the *next* release cut once fixed and re-validated through the normal PR path — no cherry-pick or merge-back into `develop` is needed since `develop` never had the revert applied.

*(Alternative to a revert commit: support ad hoc `--exclude <model>` in the RCT Slim CI selector for a given run, avoiding a revert commit at the cost of selector logic complexity. Pick one approach and document it — don't improvise per incident.)*

---

# PPD Promotion

After successful RCT validation:

```text
rct
 |
 v
ppd
```

The PPD deployment follows the same model, deploying from `release/vX.Y.Z`'s current HEAD (post any RCT-triage reverts).

```text
PPD Snowflake  -- Slim CI --
    |
    v
UAT validation
    |
    v
PPD Airflow (Argo CD sync, gated on Snowflake success)
```

Use Slim CI against the PPD environment's previous state. Do not perform an unnecessary full dbt build.

**UAT is a separate, independent gate from QA**, applied here (see "Environment Model" table). PPD deployment succeeding does not itself authorize production — it only opens the door to UAT testing.

## If UAT has not finished by the planned production date

This is an organizational decision that must be *enforced technically*, not left to convention:

* **Default: slip the production date.** Production and the sprint boundary are decoupled by design (see "Release Cadence"). The release sits in PPD; UAT continues, potentially into the next sprint's first days; `develop` and the next sprint's feature work proceed unaffected since they're independent of `release/vX.Y.Z`.
* **If this is a recurring pattern:** set an explicit UAT SLA (e.g., 2 business days from PPD deployment) with an escalation path to the product owner for an explicit go/no-go, rather than letting releases drift indefinitely. This is a calendar/communication fix, not a pipeline change.
* **Partial release:** if UAT approves some independent features in the cut but not others, apply the same `git revert` + quarantine mechanic used for RCT triage, at the release-branch level, to ship the approved subset now and carry the rest into the next cut. Only valid when features are genuinely independent — verify no cross-model dependencies before offering this option.
* **What must never happen:** merging `release/vX.Y.Z -> main` and tagging it without UAT sign-off because of sprint-end pressure. This must be structurally blocked by the required-reviewer rule on the `main`/`prd` GitHub Environment, with no override outside a documented emergency-change process that itself requires post-hoc business sign-off.

---

# Release Process

Once RCT and PPD/UAT validation are complete, finalize the release that was already cut as `release/vX.Y.Z`.

The release version was decided at cut time (see "Release Cadence and the Release Cut"). The release process from here produces:

```text
GitHub release (promoted from draft to published)
release PR into main
immutable release tag
```

---

# Release -> Main

The finalized release creates a Pull Request:

```text
release/v1.7.0 -> main
```

The PR must contain:

* Version information.
* Release notes.
* Commit range.
* RCT validation status and QA approver.
* PPD/UAT validation status and UAT approver.
* Any partial-release notes (features reverted out during RCT or PPD triage, and why).

Required reviewers on this PR/environment: **UAT/business-owner group**, in addition to the QA sign-off already recorded earlier in the process. This is the hard technical gate described above.

After approval:

```text
merge -> main
```

Then create:

```text
v1.7.0
```

as the immutable Git tag — only now, after full validation, never before.

---

# Production Deployment

Production deployments must use the release tag.

Example:

```text
v1.7.0
```

Production Snowflake deployment:

```text
Git tag v1.7.0
       |
       v
Production dbt Slim CI
       |
       v
PRD Snowflake
```

Production Airflow deployment:

```text
Git tag v1.7.0
       |
       v
Bump deploy/prd manifest ref to this tag
       |
       v
Argo CD syncs PRD Kubernetes / Airflow
```

Both must reference the exact same tag. Perform the Snowflake deploy and the Argo manifest bump-and-sync as **part of a single workflow run** triggered off tag creation, rather than two independently-triggered jobs both watching for the tag — this avoids a race where one succeeds and the other is delayed or fails silently, leaving prod Snowflake and prod Airflow briefly (or not so briefly) out of sync.

This guarantees that:

```text
Snowflake PRD
```

and:

```text
Airflow PRD
```

are deployed from the same source revision.

## Blue-green production deploys (recommended for schema/incremental changes)

For changes touching schema or incremental models, consider a clone-and-swap pattern instead of mutating prod objects in place: build into a shadow schema, validate, then atomically swap/rename. This gives near-instant rollback (swap back) independent of the git-tag rollback below, and avoids partial-deploy states if a run fails mid-way.

---

# Production Rollback

Production deployments must support rollback through a previously released Git tag.

Example:

```text
v1.7.0
v1.6.2
v1.6.1
```

A rollback must be performed by explicitly selecting a known release tag.

Do not rebuild production from an arbitrary branch commit.

Document the limitations of dbt rollback for:

* Incremental models.
* Schema changes.
* Data migrations.
* Destructive changes.

A code rollback does not automatically mean that Snowflake data can be safely rolled back.

---

# Airflow Deployment Model

Airflow runs on Kubernetes, managed via **Argo CD GitOps** (see "Dev Airflow Deployment" and "Production Deployment" above for the mechanics).

Each environment should have its own Airflow deployment or isolated environment.

Example:

```text
Kubernetes
├── airflow-dev
├── airflow-rct
├── airflow-ppd
└── airflow-prd
```

The exact Kubernetes architecture may differ, but environment isolation must be maintained.

Airflow must deploy the same dbt version/commit/tag used by the corresponding Snowflake deployment.

**Pin the Airflow runtime as a workload, not a moving target.** The deploy-manifest ref controls the DAG/dbt code; a separate, Terraform-managed image/values reference should pin the Airflow version, Python version, and ecosystem dependency set per environment. Do not let Airflow pull "latest" Helm charts or images — a two-axis drift (dbt code on one ref, Airflow runtime version silently upgraded) is exactly what produces a failed deploy at promotion time. Record the runtime version in the same deployment metadata used for Invariant 7 auditing.

Do not allow Airflow/Argo CD to independently pull arbitrary branch heads for RCT, PPD, or PRD — Argo must only ever sync against the deploy-manifest ref, which itself only advances after the matching Snowflake deployment succeeds.

---

# CI/CD Security

Credentials must be managed through GitHub Actions secrets, environments, OIDC, Vault, or another approved secret-management mechanism.

Do not store Snowflake credentials in:

```text
profiles.yml
Git
GitHub repository files
Docker images
Airflow DAG source
```

**Prefer Snowflake key-pair authentication** (or OIDC-federated short-lived credentials) over static passwords in GitHub secrets. Rotate keys on a defined schedule.

**Secrets must be distinct per environment.** Never reuse one development/CI credential across `dev`, `rct`, `ppd`, and `prd` with only a `DBT_ENV` variable swapping a database name: a leaked dev key then grants prod access, and a prod boundary change (e.g. lifting a data-restriction policy) silently weakens every environment. Provision `SNOWFLAKE_*` (and Argo/Airflow) credentials as separate GitHub Environment secrets per environment, with per-environment roles that carry only the grants that environment needs, and key rotation scheduled per environment (prod on the tightest rotation). The same per-env separation applies to dbt `profiles.yml` environment variable resolution: the variable names may be shared, but the *sources* must be distinct environment-scoped secrets.

GitHub environments should be used to enforce environment-specific permissions.

Example:

```text
github environments:

dev
rct  (required reviewers: QA group)
ppd  (required reviewers: business/UAT group)
prd  (required reviewers: UAT/business-owner group; production approval)
```

Production should require explicit approval, and this approval group must be structurally distinct from the QA group (see "Environment Model").

Restrict `workflow_dispatch` triggers on the production-deploy workflow to authorized actors/teams so a required-reviewer gate cannot be sidestepped by a differently-triggered run.

---

# GitHub Environment Protection

Configure deployment environments so that:

```text
dev
    automatic

rct
    QA approval

ppd
    UAT approval

prd
    production approval (UAT/business-owner group, distinct from QA)
```

The exact approval groups should be configurable.

The pipeline should prevent a developer — or sprint-deadline pressure — from bypassing environment approval requirements. There must be no override path outside a documented emergency-change process requiring post-hoc business sign-off.

---

# Pipeline Separation

Separate CI from CD logically.

Recommended structure:

```text
.github/
└── workflows/
    ├── feature-lint.yml          # push-triggered: lint/parse/compile only
    ├── pr-develop.yml            # PR-triggered: real build+test, Slim CI Option C
    ├── dev-deploy.yml            # merge-to-develop triggered
    ├── cut-release.yml           # workflow_dispatch: creates release/vX.Y.Z
    ├── rct-deploy.yml            # release-branch push triggered, QA-gated
    ├── ppd-deploy.yml            # post-RCT triggered, UAT-gated
    ├── release-to-main.yml       # release PR -> main, tag creation
    └── production-deploy.yml     # tag-triggered: Snowflake + Argo manifest bump, single run
```

The exact number of workflows can be reduced if a reusable workflow architecture is preferable.

Prefer reusable GitHub Actions workflows to avoid duplicating:

* dbt setup.
* Snowflake authentication.
* Slim CI logic.
* artifact handling.
* environment configuration.
* Argo CD manifest-bump logic (shared across dev/rct/ppd/prd deploy workflows).

Add a `concurrency:` group per environment on every deploy workflow to prevent races against the same state/baseline.

---

# Recommended Pipeline Architecture

```text
                         ┌──────────────────┐
                         │  Feature Branch  │
                         └────────┬─────────┘
                                  │  push
                                  v
                    ┌─────────────────────────┐
                    │ Lint / Parse / Compile  │   (no deploy, no Snowflake creds)
                    └────────────┬────────────┘
                                 │
                        Developer tests locally:
                        dbt build --target developer
                        -> ANALYTICS_<DEV>.*
                                 │
                                 v
                         ┌──────────────┐
                         │ PR -> develop│
                         └──────┬───────┘
                                │
                    ┌─────────────────────────┐
                    │ Real Slim CI build+test│   (Option C: vs dev-state,
                    │ into PR author schema   │    into developer schema)
                    └────────────┬────────────┘
                                 │  merge
                                 v
                    ┌─────────────────────────┐
                    │ Shared DEV Snowflake    │
                    │       Slim CI           │
                    └────────────┬────────────┘
                                 │
                                 v
                       ┌─────────────────┐
                       │ DEV Airflow     │  (Argo CD, gated on Snowflake success)
                       └─────────────────┘

                    ... develop accumulates further merges,
                        continuously deployed to dev only ...

                                 │
                    ┌─────────────────────────┐
                    │  workflow_dispatch:     │
                    │  cut-release vX.Y.Z     │   <- deliberate, not automatic
                    └────────────┬────────────┘
                                 │
                                 v
                    ┌─────────────────────────┐
                    │ RCT Snowflake           │
                    │       Slim CI           │
                    └────────────┬────────────┘
                                 │
                        (partial failure? git revert
                         + quarantine on release branch,
                         redeploy, re-validate scoped)
                                 │
                           QA approval
                                 │
                                 v
                       ┌─────────────────┐
                       │ RCT Airflow     │
                       └────────┬────────┘
                                │
                                v
                    ┌─────────────────────────┐
                    │ PPD Snowflake           │
                    │       Slim CI           │
                    └────────────┬────────────┘
                                 │
                           UAT approval
                          (separate gate from QA;
                           may slip past sprint end)
                                 │
                                 v
                       ┌─────────────────┐
                       │ PPD Airflow     │
                       └────────┬────────┘
                                │
                                v
                         ┌─────────────┐
                         │ PR -> main  │   (deploy+validate BEFORE merge)
                         └──────┬──────┘
                                │
                                v
                         ┌─────────────┐
                         │ Git Tag     │
                         │ vX.Y.Z      │   <- created only now
                         └──────┬──────┘
                                │
                    single workflow run, tag-triggered
                                │
                 ┌──────────────┴──────────────┐
                 │                             │
                 v                             v
       ┌──────────────────┐          ┌──────────────────┐
       │ PRD Snowflake    │          │ PRD Airflow      │
       │ Slim CI          │          │ Argo CD, exact tag│
       └──────────────────┘          └──────────────────┘
```

---

# Required dbt Configuration

The implementation should define:

```text
profiles.yml
dbt_project.yml
macros/
models/
tests/
```

with environment-dependent configuration.

The dbt project must not contain environment-specific SQL logic scattered throughout individual models.

Use dbt configuration and environment variables for:

* Database.
* Schema.
* Warehouse.
* Role.
* Target.
* Developer name.
* Environment name.

---

# Data Quality Beyond dbt Tests

Add gates beyond schema/generic dbt tests at RCT -> PPD -> PRD promotion boundaries:

* dbt source freshness checks.
* Anomaly/volume checks (e.g. dbt-expectations, or a tool like Elementary).
* dbt model contracts enforced on prod-facing marts, so a breaking column type/rename change fails CI loudly instead of silently breaking downstream BI.

---

# Required Environment Variables

Define a standard set of variables.

Example:

```text
DBT_ENV
DBT_DEVELOPER_NAME
SNOWFLAKE_ACCOUNT
SNOWFLAKE_USER
SNOWFLAKE_ROLE
SNOWFLAKE_WAREHOUSE
SNOWFLAKE_DATABASE
SNOWFLAKE_SCHEMA
```

The exact variables should be adapted to the authentication mechanism selected (key-pair auth recommended — see CI/CD Security).

---

# Deployment Invariants

The implementation must enforce these invariants.

## Invariant 1
A feature branch cannot modify shared `dev`, and cannot deploy anywhere at all via CI — only lint/parse/compile run on push.

## Invariant 2
A developer can safely deploy only into their own isolated Snowflake objects, and only from their own local machine.

## Invariant 3
`develop` deploys only to shared `dev`, continuously, on every merge.

## Invariant 4
RCT deployment requires QA approval, and is triggered only by an explicit release cut — never automatically by a `develop` merge.

## Invariant 5
PPD deployment occurs only after successful RCT validation, and requires UAT approval — a gate structurally distinct from QA's RCT approval.

## Invariant 6
PRD deployment occurs only from a versioned release tag, created only after RCT + PPD + UAT validation are all complete — never before.

## Invariant 7
Snowflake and Airflow for an environment must use the same Git revision, enforced by Argo CD syncing only against a deploy-manifest ref that is bumped only after the matching Snowflake deployment succeeds — never by Argo tracking a branch head directly.

## Invariant 8
Shared environments use Slim CI rather than unconditional full builds.

## Invariant 9
Terraform-owned infrastructure must not be recreated by dbt CI/CD. Terraform owns the developer-sandbox boundary (database, role, privilege envelope) once; it does not own individual per-developer schemas.

## Invariant 10
Production credentials and deployment permissions must not be available to ordinary feature-branch workflows.

## Invariant 11
A QA-rejected or UAT-rejected feature within a release cut must never remain in the promoted baseline — it is removed from the release branch (revert + quarantine) rather than blocking the rest of the release, and never silently re-included without re-validation.

## Invariant 12
Merging `release/* -> main` and tagging must never be bypassed under sprint-deadline pressure; the required-reviewer gate on `main`/`prd` has no override outside a documented emergency-change process with post-hoc business sign-off.

---

# Observability and Auditability

Every deployment should expose:

```text
Environment
Git SHA
Git branch/tag
Release version
dbt version
dbt state version
Deployment timestamp
GitHub workflow run
Deployed models
Tests executed
Deployment result
Approver (QA or UAT, explicitly distinguished)
```

GitHub Actions artifacts should retain relevant dbt artifacts and deployment logs, backed by the durable state store described in "Slim CI State Management" — not GitHub artifact retention alone.

The deployment history must make it possible to answer:

> Which exact dbt code is currently deployed to this environment?

> Which Git commit/tag produced this Snowflake and Airflow deployment?

> For a given release, which features were reverted out during RCT or PPD triage, by whom, and why?

---

# Failure Handling

If a deployment fails:

```text
feature -> developer (local)
```

the developer can fix and retry locally — no CI involvement.

If:

```text
develop -> dev
```

fails, the shared dev deployment must be marked failed and the new dbt state must not replace the last successful dev state.

The same rule applies to:

```text
rct
ppd
prd
```

A failed deployment must never become the new Slim CI baseline. This extends to **QA/UAT-rejected features**: even if the dbt build itself succeeded, a feature rejected during validation must be removed from the release (revert + quarantine) rather than becoming part of the promoted baseline.

---

# State Promotion Principle

Each environment owns its deployment state.

For example:

```text
DEV:
previous successful dev deployment
        |
        v
Slim CI
        |
        v
new dev deployment
        |
        v
new dev state
```

Do not update state before a deployment succeeds.

This prevents a failed deployment from corrupting future Slim CI calculations.

---

# Terraform Drift Detection

Run a scheduled (nightly/weekly) `terraform plan` on a read-only credential, alerting on drift, to catch manual Snowflake console changes to Terraform-owned objects before they cause a surprising `apply` later.

---

# Implementation Tasks

The implementation should be delivered in the following order.

## Phase 1 — Repository Structure

Create:

```text
.github/workflows/
dbt/
terraform/
scripts/            # includes quarantine_model.sh for release triage
docs/
```

and establish the reusable CI/CD workflow structure.

---

## Phase 2 — dbt Environment Configuration

Implement:

* Shared environment targets.
* Developer target.
* Environment variables.
* Developer schema naming.
* Safe target selection (schema-prefix guard rail).
* Local developer commands.

---

## Phase 3 — Terraform Sandbox Boundary + Developer Isolation

Implement and test:

* One-time Terraform provisioning of `DEV_SANDBOX` database, `DEVELOPER` role, scoped `CREATE SCHEMA` grant.
* `dbt build --target developer` and verify that `developer = alice` produces `ANALYTICS_ALICE.*` without modifying shared `dev` and without any Terraform change.
* Scheduled cleanup job for stale developer schemas.

---

## Phase 4 — Push-Stage CI (Lint/Parse/Compile Only)

Implement `feature-lint.yml`: no deployment, no Snowflake credentials, fast feedback on every push.

---

## Phase 5 — PR-Stage Real Validation (Option C Slim CI)

Implement `pr-develop.yml`:

```text
lint -> parse -> compile -> Slim CI build (vs dev-state, into PR-author's developer schema) -> tests
```

Include the schema-prefix guard rail and the automated PR comment (selected models + compiled SQL diff).

---

## Phase 6 — Dev Deployment (Continuous)

Implement:

```text
develop -> dev Snowflake -> Argo-managed dev Airflow
```

with correct ordering, concurrency control, and artifact handling.

---

## Phase 7 — Release Cut Mechanism

Implement `cut-release.yml` (`workflow_dispatch`): branch creation, draft GitHub Release, no tag yet.

---

## Phase 8 — RCT (Release-Cut Triggered, QA-Gated)

Implement:

```text
release/* push -> RCT Snowflake -> QA approval -> RCT Airflow (Argo)
```

Implement the partial-failure triage mechanic: revert + `scripts/quarantine_model.sh` + scoped redeploy.

---

## Phase 9 — PPD (RCT-Validated, UAT-Gated)

Implement:

```text
RCT validation -> PPD Snowflake -> UAT approval -> PPD Airflow (Argo)
```

Ensure UAT approval is a structurally distinct required-reviewer group from QA's RCT approval.

---

## Phase 10 — Release -> Main

Implement:

```text
release PR (post RCT+PPD+UAT) -> main -> Git tag
```

with the UAT/business-owner group as required reviewer on this PR/environment.

---

## Phase 11 — Production

Implement, as a single tag-triggered workflow run:

```text
Git tag
   |
   +--> PRD Snowflake (Slim CI, optionally blue-green)
   |
   +--> PRD Airflow (Argo CD manifest bump, same tag)
```

with production environment protection and approval.

---

## Phase 12 — Observability, Drift Detection, Documentation

Implement the durable state store, deployment metadata surfacing, scheduled Terraform drift detection, and the documentation deliverables below.

---

# Acceptance Criteria

The implementation is considered complete only when the following scenarios work.

### Scenario 1 — Developer isolation, local only
Developer Alice runs `dbt build --target developer` locally and it creates `ANALYTICS_ALICE.customer` without modifying shared `dev` and without any push-triggered CI deployment.

### Scenario 2 — Push-stage is lint/parse/compile only
Alice pushes a commit to her feature branch; CI runs lint/parse/compile, reports status, and does not touch Snowflake.

### Scenario 3 — PR-stage real validation
Alice opens a PR to `develop`; CI runs a real Slim CI build + tests into `ANALYTICS_ALICE`, using `dev` state as the comparison baseline (Option C), and posts the selected-model list as a PR comment.

### Scenario 4 — Shared Dev, continuous
The PR is merged into `develop` and the shared `dev` Snowflake environment receives the change immediately. A second, unrelated merge shortly after does not race or corrupt `dev`'s Slim CI state (concurrency group holds).

### Scenario 5 — Dev Airflow via Argo
After successful dev validation, the `deploy/dev` manifest ref is bumped to the exact deployed Git revision, and Argo CD syncs dev Airflow from that ref — not from `develop`'s head directly.

### Scenario 6 — Develop merges do not cascade to RCT
Several more merges land on `develop` over the following days. None of them trigger any RCT or PPD deployment.

### Scenario 7 — Release cut
A Release Manager runs `cut-release.yml` with `v1.7.0`. `release/v1.7.0` is created at a specific `develop` SHA including Alice's and Bob's already-merged features. A draft GitHub Release is created. No Git tag exists yet.

### Scenario 8 — RCT, partial failure
Both features deploy to RCT via Slim CI. QA approves Alice's feature and rejects Bob's. A `git revert` of Bob's merge commit is pushed to `release/v1.7.0`, the orphaned RCT object from Bob's feature is quarantined via script, RCT is redeployed, and QA re-validates only the changed scope. Bob's feature remains untouched on `develop` for a future release cut.

### Scenario 9 — PPD and UAT, separate from QA
After RCT sign-off, PPD deploys Alice's feature only. UAT testing begins as an independent gate from QA's earlier RCT approval.

### Scenario 10 — UAT slips past sprint end
UAT has not finished by the sprint's last day, despite QA having signed off days earlier. Production deployment does not happen; the release remains in PPD; `develop` and the next sprint's feature work continue unaffected; no override path exists to merge `release/v1.7.0 -> main` without the UAT/business-owner group's approval.

### Scenario 11 — Release -> Main and tag
UAT approves. The release PR `release/v1.7.0 -> main` (carrying RCT/PPD/UAT status and the note about Bob's feature being deferred) is approved and merged. Only now is the Git tag `v1.7.0` created.

### Scenario 12 — Production, single revision
The tag `v1.7.0` triggers a single workflow run deploying PRD Snowflake and bumping the `deploy/prd` Argo manifest ref to the same tag, so both deployments reference the exact same immutable Git tag with no window of mismatch.

### Scenario 13 — Failure recovery
If an RCT deployment fails outright (not a QA rejection, but a build failure), the previous successful RCT dbt state remains the baseline for the next deployment attempt.

### Scenario 14 — Terraform separation
The one-time-provisioned `DEV_SANDBOX` boundary and shared-environment schemas remain Terraform-managed; individual developer schemas are created by dbt and are never touched by Terraform; the CI/CD pipeline never recreates Terraform-owned infrastructure.

### Scenario 15 — Drift detection
A manually-made change to a Terraform-owned Snowflake object is surfaced by the next scheduled `terraform plan` drift check before it causes an unexpected `apply`.

---

# Final Deliverables

The final implementation should provide:

1. GitHub Actions workflows, split as: push-stage lint-only, PR-stage real validation, dev continuous deploy, release-cut dispatcher, RCT/PPD promotion (QA/UAT gated), release-to-main, single-run tag-triggered production deploy.
2. Reusable GitHub Actions workflows where appropriate, including shared Argo manifest-bump logic.
3. dbt target configuration (shared + developer targets).
4. Developer-isolated target configuration with schema-prefix guard rail.
5. Slim CI implementation for all four shared environments plus PR-stage Option C.
6. Durable dbt state artifact management (not reliant on GitHub Actions artifact retention).
7. Snowflake deployment scripts, including `scripts/quarantine_model.sh` for release-triage cleanup.
8. Airflow/Kubernetes deployment integration via Argo CD GitOps, with per-environment deploy-manifest refs.
9. GitHub environment protection configuration with QA and UAT modeled as structurally distinct required-reviewer groups.
10. Release/versioning automation (branch-based cut mechanism; optional release-please/semantic-release for version computation only).
11. Production tag-based deployment as a single atomic workflow run (Snowflake + Argo, same trigger).
12. Terraform: one-time developer-sandbox boundary + scheduled drift detection.
13. Documentation for developers (local workflow, push vs PR-stage CI distinction).
14. Documentation for QA (RCT gate, partial-failure triage process).
15. Documentation for UAT/business owners (PPD gate, SLA/escalation policy, what a slipped release means).
16. Documentation for release managers (cut timing guidance, release PR checklist, partial-release procedure).
17. Rollback documentation (tag-based rollback, blue-green option, data-rollback caveats).
18. Architecture diagram (as in "Recommended Pipeline Architecture").
19. Troubleshooting guide, including the "orphaned object after revert" quarantine scenario.

The implementation should prioritize a simple developer experience while maintaining strict environment isolation, clearly separated QA/UAT approval, and production deployment controls that cannot be bypassed under schedule pressure.
