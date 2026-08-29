# Maintaining the Petrushin AI Sure fork

This repository is a native GitHub fork of [`we-promise/sure`](https://github.com/we-promise/sure).
It keeps a small set of production-required downstream patches for the
`f.teknologia.org` deployment.

## Ownership boundary

- `petrushin-ai/sure` owns source changes, the downstream patch, tests, and
  the multi-architecture image build.
- `we-digital/devops` owns the pinned production image digest, backups,
  rollout, health verification, and rollback.
- Never deploy a mutable branch or tag. Merge a reviewed fork PR, wait for the
  publish workflow, inspect the OCI revision, and pin the resulting index
  digest in `deployments/sure-teknologia/compose.yml`.

## Source-of-truth artifacts

- `.upstream-commit` records the exact upstream commit currently incorporated
  into the fork. Use a full 40-character SHA.
- `petrushin-ai-custom.patch` is the complete diff from that upstream commit
  to the fork, excluding the patch file itself.
- `bin/regenerate-downstream-patch` regenerates the patch after an intentional
  downstream change.
- `bin/verify-downstream-patch` proves that the committed patch matches the
  tree and applies cleanly to the recorded upstream commit.
- `bin/upgrade-upstream` creates an upgrade branch from a newer upstream ref,
  applies the patch with Git's three-way merge support, advances the marker,
  and regenerates the patch.

CI runs `bin/verify-downstream-patch` on every fork PR and before every image
publish. A stale or non-applicable patch is a hard failure.

## Active downstream patch ledger

### SURE-001 — OpenAI PDF vision token limit

- Source: [`petrushin-ai/sure#1`](https://github.com/petrushin-ai/sure/pull/1),
  merge commit `e72f4f5467ea36a895417cf71cfd8934e94c2b1e`.
- Purpose: official OpenAI Chat Completions requests use
  `max_completion_tokens`; custom OpenAI-compatible endpoints retain
  `max_tokens` for compatibility.
- Main conflict area: `app/models/provider/openai.rb` and the OpenAI PDF
  processor tests.
- Retirement rule: remove only after upstream supports both request shapes
  with equivalent regression coverage.

### SURE-002 — PDF vision runtime dependency

- Source: [`petrushin-ai/sure#2`](https://github.com/petrushin-ai/sure/pull/2),
  merge commit `76b8fd0dab50f133f220e18d38189e93678f44bd`.
- Purpose: install `poppler-utils`, which provides the `pdftoppm` executable
  used to convert scanned PDF pages before vision processing.
- Main conflict area: `Dockerfile` runtime packages.
- Retirement rule: remove only when the upstream runtime supplies a verified
  PDF-to-image implementation used by `Provider::Openai::PdfProcessor`.

### SURE-003 — Exact PDF classification and metadata schema

- Source: [`petrushin-ai/sure#3`](https://github.com/petrushin-ai/sure/pull/3),
  merge commit `a6d5d34f28dd2dbd4401a5031cea22f2b6b5d283`.
- Purpose: share one strict classification/metadata JSON Schema between
  OpenAI and Anthropic; reject missing, malformed, or additional fields; and
  validate exact synthetic metadata through both PDF processing paths.
- Main conflict areas: `app/models/provider/llm_concept.rb`, both provider PDF
  processors, `app/models/ai_health*`, System Health UI/locales, and their
  tests.
- Retirement rule: remove only after upstream has an equally strict shared
  contract and distinguishes schema failures from recognition failures.

### SURE-004 — Exact bank-statement transaction schema

- Source: [`petrushin-ai/sure#4`](https://github.com/petrushin-ai/sure/pull/4),
  merge commit `ade989b7401acd982f45a90fbc726a21da0e54e5`.
- Purpose: enforce Sure's canonical bank-statement structure for bank/account
  metadata, statement period, balances, and every transaction's date,
  description, signed amount, reference, and category. Official OpenAI uses
  Structured Outputs, Anthropic uses the same tool schema, and compatible
  providers are normalized and validated before acceptance.
- Main conflict areas: `app/models/provider/llm_concept.rb`, both bank
  statement extractors, AI health probes/UI, and provider/health tests.
- Retirement rule: remove only after upstream provides the same canonical
  schema, runtime validation, explicit failure behavior, and end-to-end
  transaction-recognition health probe.

### SURE-005 — Fork maintenance guardrails

- Source: this document, `.upstream-commit`,
  `petrushin-ai-custom.patch`, the three `bin/*downstream*`/upgrade commands,
  and the `downstream_patch` CI job.
- Purpose: make loss or silent drift of SURE-001 through SURE-004 detectable
  during every ordinary change and every upstream update.
- Retirement rule: keep while any downstream patch remains active.

### SURE-006 — Complete native Binance balance synchronization

- Source: [`petrushin-ai/sure#6`](https://github.com/petrushin-ai/sure/pull/6)
  and [`docs/hosting/binance.md`](hosting/binance.md); record the merge commit
  here after merge.
- Purpose: synchronize Spot, Funding, Cross/Isolated Margin, Simple Earn,
  BFUSD/RWUSD, USDⓈ-M/COIN-M Futures, Options and Portfolio Margin directly
  from Binance; exclude current positions worth less than `$1`; retain
  unpriced or temporarily unavailable assets; surface per-source diagnostics;
  and enqueue active connections every four hours without an external service.
- Main conflict areas: `app/models/provider/binance.rb`, `app/models/binance_item*`,
  `app/models/binance_account*`, `app/jobs/sync_binance_job.rb`,
  `config/schedule.yml`, Binance tests and the hosting guide.
- Retirement rule: remove only after upstream provides equivalent account-type
  coverage, Portfolio Margin de-duplication, pagination, `$1` cutoff semantics,
  partial-source retention/diagnostics, and native scheduled synchronization.

If upstream absorbs a patch, record the upstream PR and commit here, compare
behavior and tests, remove only the duplicated downstream implementation, and
regenerate the patch. Do not silently delete a ledger entry.

## Ordinary downstream changes

Every downstream code change must update this ledger when its behavior or
retirement condition differs from the existing entries. After committing the
source change:

```bash
bin/regenerate-downstream-patch
git add petrushin-ai-custom.patch docs/UPSTREAM.md
git commit --amend --no-edit
bin/verify-downstream-patch
```

The patch must remain a deterministic representation of the complete fork
delta, not a hand-edited selection of hunks.

## Upstream update procedure

### 1. Pre-flight

```bash
git status --short --branch
git fetch origin --prune
git fetch upstream --prune --tags
git switch main
git merge --ff-only origin/main
cat .upstream-commit
bin/verify-downstream-patch
```

Review the upstream delta before applying it:

```bash
git log --oneline "$(cat .upstream-commit)..upstream/main"
git diff --stat "$(cat .upstream-commit)..upstream/main"
git diff --name-only "$(cat .upstream-commit)..upstream/main"
```

Compare changed upstream files with every conflict area in the active ledger.
If upstream implemented similar behavior, inspect it semantically instead of
blindly retaining both versions.

### 2. Create the upgrade branch and reapply the patch

```bash
bin/upgrade-upstream upstream/main
```

The command:

1. requires a clean tree and fast-forwards local `main` to `origin/main`;
2. verifies the existing downstream patch;
3. rejects downgrades or a target outside the recorded upstream lineage;
4. creates a local safety tag and an upgrade branch from the exact target
   upstream commit;
5. applies `petrushin-ai-custom.patch` with `git apply --3way`;
6. updates `.upstream-commit`, commits the reapplied changes, regenerates the
   patch, and verifies it in a detached worktree.

If application conflicts, the command stops without committing. Resolve each
conflict against the ledger, run the focused tests below, commit the resolved
tree, regenerate the patch, and rerun `bin/verify-downstream-patch`.

### 3. Required verification

```bash
bin/verify-downstream-patch
bin/rails test \
  test/models/provider/llm_concept_test.rb \
  test/models/provider/openai/pdf_processor_test.rb \
  test/models/provider/openai/bank_statement_extractor_test.rb \
  test/models/provider/anthropic/pdf_processor_test.rb \
  test/models/provider/anthropic/bank_statement_extractor_test.rb \
  test/models/ai_health/probe_test.rb \
  test/controllers/admin/system_health_controller_test.rb
bin/rails test \
  test/models/provider/binance_test.rb \
  test/models/binance_item \
  test/models/binance_account \
  test/jobs/sync_binance_job_test.rb
bin/rails test:system TEST=test/system/admin/system_health_test.rb
bin/rubocop \
  app/models/ai_health.rb \
  app/models/ai_health/probe.rb \
  app/models/provider/llm_concept.rb \
  app/models/provider/openai.rb \
  app/models/provider/openai/pdf_processor.rb \
  app/models/provider/openai/bank_statement_extractor.rb \
  app/models/provider/anthropic/pdf_processor.rb \
  app/models/provider/anthropic/bank_statement_extractor.rb
bin/rails zeitwerk:check
```

Also run the full GitHub CI suite. Provider preflight must use a synthetic PDF
with no customer data and must confirm exact metadata plus exact transaction
values; successful HTTP status alone is insufficient.

### 4. PR, build, and deploy

Always specify the fork explicitly so a PR cannot be opened against upstream:

```bash
git push -u origin chore/upstream-<target-sha>
gh pr create --repo petrushin-ai/sure --base main \
  --head chore/upstream-<target-sha>
```

After merge:

1. wait for `Publish Docker image` to finish successfully;
2. verify the OCI index contains amd64 and arm64 and that
   `org.opencontainers.image.revision` equals the fork merge commit;
3. update only the immutable digest in
   `we-digital/devops/deployments/sure-teknologia/compose.yml`;
4. follow `we-digital/devops/docs/runbooks/sure-teknologia.md` for backup,
   guarded deployment, live AI probes, and rollback.

## Rollback

- Before merge, return to the local safety tag printed by
  `bin/upgrade-upstream`; never force-push `main`.
- After deployment, restore the previous image digest through
  `we-digital/devops` and rerun its deployment procedure.
- If an upstream update includes forward-only data migrations, use the
  verified pre-change backup rather than assuming an image-only rollback is
  sufficient.
