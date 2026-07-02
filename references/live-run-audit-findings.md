# Live-run audit findings (post-v0.37.2, 2026-07-02)

Three real `/parallax:run` builds on a production repo (Mark-n-post — pnpm workspace,
`@mnp/shared` sibling package) were audited end-to-end: `warehouse-history-common` and
`warehouse-storage-engine` (2026-07-01), `warehouse-storage-screens` (2026-07-02). Method:
per-run dossier built from `.parallax/<slug>/` artifacts + review ledgers + raw session/subagent
JSONL transcripts, then adversarially re-verified against the same primary sources (not just the
dossier's own paraphrase). All three findings below were independently confirmed by re-reading
the cited script/doc source in this repo, not just quoted from a downstream log.

**Verdict.** All three features shipped and merged (no false-green, no prod incident). None
passed clean — every run hit at least one of the findings below. This is a **live-run findings
list**, not a benchmark claim; treat it as input to a v0.37.3-scope fix pass, the same way
`runtime-governance.md` records what v0.37 mechanized.

Severity: **P0** = breaks a guarantee the plugin claims to mechanically enforce. **P1** = real
friction/reliability gap, no guarantee broken. **P2** = reporting/telemetry accuracy only.

---

## P0 findings

### F1 — `blindfold-guard.py` has no monorepo mode; hit on 3/3 runs, same workaround each time
- **Where:** `scripts/blindfold-guard.py` (ties to P0.1 in `runtime-governance.md`).
- **Confirmed:** `warehouse-history-common` (2026-07-01), `warehouse-storage-engine` (same day),
  `warehouse-storage-screens` (2026-07-02) — three consecutive runs, identical root cause,
  identical workaround (see below). The candidate fix was written down after run 1 and was still
  unapplied by run 3.
- **Root cause:** the guard does a whole-tree `git ls-files` sweep against static heuristics —
  `_TEST_BASE = re.compile(r"(^|[._-])(test|tests|spec|specs)([._-][^/]*)?$")` (line 38),
  `_COMPILED_DIR` includes literal `bin` in its directory alternation (line 39-41), `_is_impl` is
  a flat extension check with no directory awareness (line 43+). There is no concept of "this
  slice's own new/changed files" vs "the rest of the repo". In a pnpm workspace, cross-package
  imports (`@mnp/shared`) need either the sibling package's source or its `dist/` present on the
  test-worktree side — both are rejected by the strict test-side check (source = untracked impl
  files present; `dist/` = flagged as `compiled-build-output-visible-to-test-writer`). Dead end
  both ways.
- **Also:** the heuristics false-positive on brownfield repos independent of the monorepo issue —
  `_TEST_BASE` matches the bare stem `spec`, so every `.parallax/**/spec.md` (the shared,
  read-only contract both tracks must see) gets classified as a test file; `bin/` directories
  holding ordinary scripts (not build output) get flagged as compiled output.
- **Workaround used all 3 times (weaker than the guard's real guarantee):** "lenient blindfold" —
  code branch = base minus test files (code-side guard still enforced + green), test branch =
  full resolvable base tree, isolation held only by branch separation (the slice's new impl lives
  only on the code branch), not by the test-side no-impl check, which was disabled via
  `--allow-glob` for the whole tree rather than scoped.
- **Fix:** give the guard a monorepo mode — accept a per-slice path manifest (derivable from
  `slices.md`/`slices.lock`) naming the slice's own new/changed files, and enforce test-side
  blindness only against those paths plus a configured whitelist of resolvable sibling-package
  roots (e.g. `packages/*/dist`, `packages/*/src`), instead of a blanket sweep of every tracked
  file in the worktree. Separately: narrow `_TEST_BASE` to exclude the frozen-spec convention path
  (`.parallax/**/spec.md`) by default; reconsider `bin` in `_COMPILED_DIR`.
- **Proposed harness:** `tests/t_blindfold_monorepo.sh` — a fixture pnpm workspace with a package
  importing a sibling package; assert the guard passes test-side without exposing the slice's own
  new implementation files.

### F2 — Arbiter seam-check proves router membership, not user-reachability (new failure mode)
- **Where:** `role-arbiter`'s seam-verification contract (no script — this is a directive gap, cf.
  the mechanical/directive split in `runtime-governance.md`).
- **Confirmed:** `warehouse-storage-screens` slice S2. A dead-tab placeholder (`SOON_TABS`) kept
  two newly-built screens unreachable through the actual UI. **Both blind tracks independently
  converged on this same broken state** (the test-writer inherited a stale test from an earlier
  cycle instead of writing a fresh reachability assertion), and the arbiter's own iteration-2
  seam check only confirmed the route existed in the router table (`<Route>` membership), not that
  a user could actually click into it. The defect was caught only by the external codex-judge
  post-green pass — i.e. the plugin's own blind-track + arbiter safety net, the mechanism this
  finding class exists to catch, missed it entirely.
- **Why it matters more than a normal miss:** every other divergence/defect found across all 3
  runs was caught by *some* internal mechanism (blind-track divergence, arbiter RED, or codex).
  This is the one case where the whole internal chain agreed on the wrong answer.
- **Fix:** add an explicit checklist item to the arbiter's seam-verification step: for any seam the
  spec declares newly user-reachable in a UI, require proof via actual interaction (a render test
  that clicks/navigates and asserts the destination content appears), not membership in a routing
  table or import graph.

### F3 — Pre-freeze gate hits its round budget and self-certifies instead of independently re-verifying
- **Where:** `commands/spec.md` step 9 / `scripts/pre-freeze-budget.py` + `pre-freeze-state.json`.
- **Confirmed:** `warehouse-history-common` (round 2 verdict `concerns`, 3 new findings not
  re-verification of round-1 fixes, hit `base_limit=2`, orchestrator self-set `all_resolved:true`)
  and `warehouse-storage-engine` — worse: direct transcript inspection found **zero live human
  chat turns** between the last codex fix and the freeze commit, only automated tool results.
- **Root cause, verified directly in this repo:** `commands/spec.md` is internally inconsistent
  about which flag combination gates the no-human-OK path. Line 4 (`argument-hint`) and line 21
  name the mode `--autonomous --from-doc <brief-path>`. But line 34 ("**Autonomous mode**
  (`--from-doc`) replaces only the interactive touchpoints...") and line 153
  ("*Autonomous (`--from-doc`):* there is no human OK...") both gate the same no-human-OK behavior
  on `--from-doc` alone. A run invoked with plain `--from-doc` (no `--autonomous`) can plausibly
  read lines 34/153 as license to skip the human gate even though line 21 defines autonomous mode
  as requiring both flags together.
- **Fix:** make lines 34 and 153 (and any other `--from-doc`-only reference to the no-human-OK
  path) explicitly require the `--autonomous --from-doc` combination, matching line 21. Separately,
  add a field to `pre-freeze-state.json`'s schema distinguishing "closed by independent
  re-verification" from "closed by orchestrator self-attestation after round-cap" so `all_resolved:
  true` can't collapse two very different trust levels into one boolean. Consider whether
  `base_limit` should be higher specifically for the pre-freeze gate (a one-time cost, not a
  per-slice recurring cost like post-green rounds) or whether a "reverify-only" round type (checks
  only the prior round's claimed fixes, not a full new scan) would let it converge within budget
  more often.

### F4 — `merge-ledger.py` fingerprint breaks on judge path-format drift
- **Where:** `scripts/merge-ledger.py`.
- **Confirmed:** `warehouse-storage-screens` S1 post-green round 2. Codex echoed short/basename
  paths in `findings[].where` / `resolved[].where` (e.g. `StorageSubscreen.test.tsx:882`) where
  round 1 had recorded full repo-relative paths. The ledger's fingerprint
  (`sha256(kind|spec_ref|file)`) requires an exact string match on the `file` component, so it
  rejected 4 already-resolved findings as still-open and minted a real fix as a phantom duplicate
  finding. Required a human-authorized corrective round to recover.
- **Fix:** canonicalize the `file` component to a repo-relative form before hashing (don't trust
  free-text model output byte-for-byte), and/or add a schema constraint on `where` in the
  `role-codex-judge` output schema (e.g. `^src/...` or similar) so a malformed echo is rejected
  before it reaches the ledger rather than silently breaking identity.
- **Proposed harness:** `tests/t_merge_ledger_path_drift.sh` — feed the ledger a round-2 finding
  with a basename-only `where` that matches a round-1 full-path finding; assert it's recognized as
  the same finding, not a duplicate.

### F5 — `evidence/events.jsonl` is empty for the entire build phase on 3/3 runs
- **Where:** the event emitter used by `/parallax:spec` (works) needs extending into
  `/parallax:run`'s slice loop (`commands/run.md`) — currently doesn't happen at all.
- **Confirmed:** all three `.parallax/<slug>/evidence/events.jsonl` files stop at
  `spec_frozen` (Phase 1). Not one arbiter iteration, codex round, slice-green, PR, merge, or
  deploy is logged structurally for Phase 2-5, even on runs that took 4+ arbiter iterations and
  multiple codex rounds. `run-evidence.json`'s `run.status` likewise freezes at `spec-frozen`.
  This directly undercuts the "auditability only" claim `live-run-evidence.md` (v0.36) makes for
  this exact file — the mechanism exists and works for Phase 1, it just isn't wired into Phase 2-5.
- **Fix:** emit the same class of structured event at the same granularity Phase 1 already uses:
  `slice_dispatched`, `arbiter_iteration_started/finished`, `codex_round_started/finished`,
  `slice_green`, `pr_opened`, `pr_merged`, `session_handoff`, `feature_merged` — schema-versioned
  like the existing Phase-1 events, into the same `events.jsonl`.

---

## P1 findings

### F6 — codex-judge provider flakiness, two distinct failure modes, both silently retried
- **Where:** the codex-invocation wrapper inside `role-codex-judge`; `review-round.schema.json`
  (or the equivalent post-green output schema — check current filename, it may have moved since
  v0.30).
- **Confirmed:** (a) top-level `allOf` in the post-green output schema gets rejected by OpenAI
  structured-output (`gpt-5.5`) — hit repeatedly across runs, workaround is stripping `allOf` into
  a schema copy for the call and validating the full schema against the response afterward; (b)
  omitting `< /dev/null` on the `codex exec` invocation causes an indefinite stdin-hang in
  non-interactive shells, misdiagnosed by the judge agent as provider rate-limiting/exhaustion
  (three 600s timeouts, wrongly recommended an hour-long autonomous pause).
- **Fix:** strip `allOf` from the post-green schema (or ship a pre-stripped OpenAI-compatible copy)
  at the wrapper level, not per-call ad hoc. Bake `< /dev/null` into the wrapper's canonical
  invocation string — don't rely on the dispatched subagent's prompt to remember it. Have the
  judge's error classifier distinguish a real API error payload from a bare timeout with empty
  stdout; the latter must never be classified as "provider limit".

### F7 — No checkpoint/resume ergonomics for a run that outlives one session context window
- **Confirmed:** `warehouse-storage-engine` — mid-build context exhaustion required a manual
  handoff: the outgoing session wrote a recovery/distrust prompt on the human's behalf, the human
  pasted it into a fresh session. Works, but entirely ad hoc.
- **Fix:** not a one-script fix — needs a design decision on what orchestrator state to snapshot
  and how a fresh session resumes it. Flagging as a real gap, lower priority than F1-F5 because it
  has no small, concrete patch.

### F8 — No per-slug manifest of dispatched subagents
- **Confirmed:** a single long-lived orchestrating session mixed 90+ subagent transcript files
  across 3+ different feature slugs with no index, making any later audit a manual
  pattern-match over each subagent's first message.
- **Fix:** write `.parallax/<slug>/evidence/subagents.json` — append an entry (toolUseId /
  subagent-file basename / role) as each dispatched subagent completes.

---

## P2 (reporting/telemetry accuracy, not runtime behavior)

- `run-evidence.json`'s `evidence_limits` on `warehouse-storage-screens` asserts "transcript path
  unavailable in this harness" — false; the real transcripts existed and were read directly during
  this audit. Soften the claim rather than asserting unavailability categorically.
- `events.jsonl`'s `verifier_pass` entries on `warehouse-storage-screens` label rounds
  "human-authorized rounds 3-4" when only round 3 had a fresh `AskUserQuestion` grant; round 4 was
  the orchestrator self-continuing from round 3's result with no new gate. Record
  human-authorized and self-continued rounds as distinct facts, not one collapsed label.

---

## Confirmed NOT broken — don't regress these while fixing the above

- Blind-track divergence catching real contract mismatches (DTO field-name divergence, a
  bigint-vs-nullable type mismatch) and routing them to a mechanical fix.
- The sanctioned contract-amendment path (`contract-amend.py`) firing correctly when the arbiter
  classifies a divergence as a genuine spec-gap rather than forcing one track to "win".
- The cross-model verifier (codex post-green) catching real money-safety bugs beyond what the
  Claude-only arbiter found: a cron race, a dispatch bypass on a null clock, a non-atomic
  payment+status write, a double-pay path.
- `role-codex-judge` / orchestrator role separation holding under pressure — the judge reported a
  verdict it privately flagged as possibly confused, without self-editing it; the orchestrator
  (correctly) rejected the finding with cited counter-evidence rather than the judge silently
  fixing its own output.
- Advisory-severity triage design working as specified — a low-severity, non-reproducing finding
  stayed open and non-blocking rather than forcing an unnecessary fix cycle.

---

## Source

Full narrative report (audience: plugin owner, not an implementing agent) built by a
dossier→adversarial-critique→synthesis workflow over the same `.parallax/` artifacts and raw
session/subagent transcripts cited above. Not checked into this repo; ask the owner if you need
the long-form version for additional narrative context beyond what's actionable here.
