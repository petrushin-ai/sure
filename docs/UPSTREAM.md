# Maintaining the Petrushin AI Sure fork

This repository is a native GitHub fork of [`we-promise/sure`](https://github.com/we-promise/sure).
It keeps a small set of production-required downstream patches for the
`f.teknologia.org` deployment.

## Ownership boundary

- `petrushin-ai/sure` owns source changes, the downstream patch, tests, and
  the multi-architecture image build.
- `we-digital/devops` owns the pinned production image digest, backups,
  rollout, health verification, and rollback.
- Never deploy a mutable branch or tag. Approved Teknologia changes are
  committed directly to `petrushin-ai/sure:main` without a PR. Every code
  commit must include this ledger and a regenerated, verified downstream
  patch. Wait for the publish workflow, inspect the OCI revision, and pin the
  resulting index digest in `deployments/sure-teknologia/compose.yml`.

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

CI runs `bin/verify-downstream-patch` on every fork change and before every
image publish. A stale or non-applicable patch is a hard failure.

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
  and [`docs/hosting/binance.md`](hosting/binance.md), merge commit
  `04c72b983d94a63c0eb1419c6d7c0f4b56e33474`.
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

### SURE-007 — Multiple named Binance connections

- Source: direct `main` change authorized for the Teknologia fork and
  [`docs/hosting/binance.md`](hosting/binance.md).
- Purpose: allow one family to connect multiple Binance API key pairs, name
  each connection and imported Sure account independently, preserve existing
  credentials during name-only edits, reject a duplicate active key within a
  family, keep every import scoped to its owning connection, and stagger
  scheduled connection syncs to reduce Binance rate-limit bursts.
- Main conflict areas: `app/models/binance_item.rb`,
  `app/models/binance_item/importer.rb`, `app/controllers/binance_items_controller.rb`,
  Binance settings/setup views and locales, and the scheduled Binance jobs.
- Retirement rule: remove only after upstream supports multiple independently
  named Binance credentials per family with connection-scoped imports,
  non-destructive credential edits, duplicate-key protection, stable account
  names and bounded scheduled fan-out.

### SURE-008 — Capability-aware Binance authentication and credential status

- Source: direct `main` production fix for the Teknologia fork and
  [`docs/hosting/binance.md`](hosting/binance.md).
- Purpose: send signed Funding Wallet POST parameters in HTTParty's supported
  hash form; validate the key/IP pair against Spot while treating permission
  denials from optional Binance products as source-specific unavailability;
  sanitize unexpected HTML provider errors; and show an explicit encrypted
  credential-saved indicator without redisplaying secrets.
- Main conflict areas: `app/models/provider/binance.rb`, all optional
  `app/models/binance_item/*_importer.rb` sources, Binance provider/importer
  tests, the Binance settings panel and locales.
- Retirement rule: remove only after upstream both supports signed POST
  requests and distinguishes invalid base credentials from unavailable
  account-type capabilities without losing the successful sources.

### SURE-009 — Canonical Binance crypto security identity

- Source: direct `main` production fix for the Teknologia fork and
  [`docs/hosting/binance.md`](hosting/binance.md).
- Purpose: resolve every Binance asset to its exact `CRYPTO:<asset>` security
  instead of allowing generic provider search to fuzzy-match an unrelated
  fiat market pair. This keeps holding identity stable and prevents the first
  account materialization from issuing a foreign-exchange request for every
  asset and historical date.
- Main conflict areas: `app/models/binance_account/security_resolver.rb`,
  Binance holdings/trade processing and resolver tests.
- Retirement rule: remove only after upstream guarantees exact crypto asset
  identity for provider imports and cannot substitute a quote-currency market
  pair for a bare Binance asset.

### SURE-010 — Native comprehensive OKX connector

- Source: direct owner request in `#devops`, 2026-08-29.
- Status: active downstream product integration.
- Files: `app/models/provider/okx.rb`, `app/models/provider/okx_adapter.rb`, `app/models/okx_item*`,
  `app/models/okx_account*`, `app/controllers/okx_items_controller.rb`,
  `app/jobs/sync_okx*`, provider settings UI/locales, database migration, tests,
  and [`docs/hosting/okx.md`](hosting/okx.md).
- Purpose: connect multiple named OKX main/sub-accounts directly with encrypted
  read-only key/secret/passphrase credentials; import non-overlapping Unified,
  Funding, Earn/Staking, OKUSD and loan value into one combined account per key;
  retain all official product ledgers and diagnostics without double counting
  account-wide staking, bots, copy trading or Stable Rewards aggregates; apply
  the strict `< $1` holding cutoff; preserve last-good source snapshots on
  partial failures; and run an isolated staggered four-hour native sync.
- Main conflict areas: family provider panels, `Account` crypto factory,
  `config/routes.rb`, `config/schedule.yml`, provider metadata, database schema,
  crypto security resolution and provider-sync health aggregation.
- Retirement rule: remove only after upstream ships an OKX v5 connector with
  equivalent three-part signing and clock correction, multiple connections,
  comprehensive product coverage, aggregate-aware no-double-count semantics,
  exact crypto identity, `$1` boundary behavior, partial-source carryover,
  history retention diagnostics and isolated scheduled sync.
- Account integration requirement: keep `OkxAccount` registered with
  `Provider::Factory` through `Provider::OkxAdapter`. Account pages and
  post-sync processing resolve every linked provider through this factory, so
  the OKX account model alone is insufficient and causes request-level render
  failures after a successful import.
- Accounts-index requirement: load and render `OkxItem` cards alongside the
  other provider collections, include them in access filtering and sync
  metadata preloading, and broadcast the card after sync. A linked
  `OkxAccount` is otherwise valid in the database but invisible on `/accounts`.
- UI requirement: both OKX and Binance account-setup date and account-name
  controls must use the Sure `StyledFormBuilder`/`form-field`/
  `form-field__input` design system. Dark theme must also set the native date
  input `color-scheme` so the browser picker, field background, text and
  calendar indicator remain legible.

### SURE-011 — Canonical crypto portfolio aggregation

- Source: direct owner request in `#devops`, 2026-08-29.
- Status: active downstream portfolio correction.
- Purpose: keep provider-neutral `CRYPTO:<asset>` security identity while
  displaying one portfolio row per economic crypto asset; sum value and
  quantity across Binance, OKX and other institutions in family currency;
  calculate weight against the complete investment portfolio; and expose the
  exact Sure-account breakdown without encoding an institution into the
  ticker. Materialize one holding per asset inside each combined Binance/OKX
  account so Spot, Funding, Earn and other product rows add together instead
  of overwriting the same `(account, security, date, currency)` holding.
- Main conflict areas: `Security#crypto?`, `InvestmentStatement` portfolio
  aggregation, the dashboard investment summary, Binance/OKX holdings
  processors, and their model/controller tests.
- Retirement rule: remove only after upstream groups provider-neutral crypto
  identities across accounts, preserves institution-level drill-down, uses a
  portfolio-level weight denominator, and materializes every combined exchange
  account without last-source-wins holding loss.

### SURE-012 — Read-only TON/GRAM wallets with TonConnect onboarding

- Source: direct owner requests in `#devops` thread `1788013521.324599`,
  2026-08-29.
- Status: active downstream product integration. It remains covered by the
  repository's AGPLv3 source obligations; "proprietary" here means maintained
  only in this downstream fork, not closed source for network users.
- Purpose: add TON mainnet to the universal on-chain wallet model; canonicalise
  raw, bounceable and non-bounceable addresses; import native GRAM and Jetton
  balances plus bounded, idempotent transfer history through TON Center API v3;
  identify Jettons by master contract and preselect only an explicit allowlist;
  stitch Binance's historical `TONUSDT` series to `GRAMUSDT`; and let users pick
  a mainnet wallet through TonConnect without ever requesting proof, signing,
  transaction or key material. Session restoration is disabled so an
  unavailable bridge cannot block the picker or reuse another Sure login's
  wallet on a shared browser; the modal opens directly from the user's click,
  and the new session is disconnected before the public address enters the
  ordinary read-only linking flow.
- Main conflict areas: `Onchain::Chains`, the TON address/adapter and TON Center
  provider, `OnchainWalletItem` encrypted connection settings, partial asset
  uniqueness indexes, the on-chain linking UI/importmap and manifest route,
  `Provider::BinancePublic`, translations, tests and
  [`docs/hosting/onchain-wallets.md`](hosting/onchain-wallets.md).
- Retirement rule: remove only after upstream provides equivalent TON mainnet
  address safety, native GRAM and Jetton identity/history semantics, optional
  TON Center credentials and bounded queries, read-only TonConnect onboarding,
  TON-to-GRAM price continuity, schema guarantees and regression coverage.

If upstream absorbs a patch, record the upstream PR and commit here, compare
behavior and tests, remove only the duplicated downstream implementation, and
regenerate the patch. Do not silently delete a ledger entry.

## Ordinary downstream changes

Every downstream code change must update this ledger when its behavior or
retirement condition differs from the existing entries. The source, ledger and
generated patch belong in one final direct-main commit. Create the local commit
from the source and ledger first so the generator can diff `HEAD`, then amend
the generated patch into that same commit before pushing:

```bash
git add <source-and-test-files> docs/UPSTREAM.md
git commit -m "Describe the downstream change"
bin/regenerate-downstream-patch
git add petrushin-ai-custom.patch
git commit --amend --no-edit
bin/verify-downstream-patch
git push origin main
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
bin/rails test \
  test/models/provider/okx_test.rb \
  test/models/okx_item_test.rb \
  test/models/okx_item/importer_test.rb \
  test/models/okx_account/holdings_processor_test.rb \
  test/controllers/okx_items_controller_test.rb \
  test/jobs/sync_okx_job_test.rb
bin/rails test \
  test/models/security_test.rb \
  test/models/investment_statement_test.rb \
  test/controllers/pages_controller_test.rb
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

After changing JavaScript, do not let an older local `public/assets` build
shadow the source during a system test. Precompile the candidate commit or move
the generated directory aside for the test and restore it afterward.

### 4. Direct-main build and deploy

Keep the verified rebase result and regenerated patch in the same commit, then
push the fork explicitly. Do not open a PR for Teknologia fork changes:

```bash
git switch main
git merge --no-ff --no-edit chore/upstream-<target-sha>
bin/verify-downstream-patch
git push origin main
```

After push:

1. wait for `Publish Docker image` to finish successfully;
2. verify the OCI index contains amd64 and arm64 and that
   `org.opencontainers.image.revision` equals the pushed fork commit;
3. update only the immutable digest in
   `we-digital/devops/deployments/sure-teknologia/compose.yml`;
4. follow `we-digital/devops/docs/runbooks/sure-teknologia.md` for backup,
   guarded deployment, live AI probes, and rollback.

## Rollback

- Before pushing `main`, return to the local safety tag printed by
  `bin/upgrade-upstream`; never force-push `main`.
- After deployment, restore the previous image digest through
  `we-digital/devops` and rerun its deployment procedure.
- If an upstream update includes forward-only data migrations, use the
  verified pre-change backup rather than assuming an image-only rollback is
  sufficient.
