# Frontend user-reachability — prompt-level regression cases (v0.37.3 F2)

These exercise the v0.37.3 **user-reachability seam proof** across four contracts:
`/parallax:spec` (Step 6 — the slice manifest marks each frontend seam
`internal/import-only` | `route-registered` | `user-reachable`), `/parallax:run`
(the arbiter dispatch text carries the interaction-proof requirement),
`role-arbiter` (membership isn't proof for a user-reachable seam), and
`role-test-writer` (no stale route-membership test where the spec demands user
reachability). This is **directive / prompt-contract hardening, not a deterministic
runtime proof**: `tests/run.sh` locks only the wiring presence (`[ui_reachability]`);
whether a live arbiter actually demands the interaction test is LLM-judged — these
cases are that behavioural eval set, run by a human or a judging model.

## The live failure this encodes (why the set exists)
`warehouse-storage-screens` slice S2 (2026-07-02, Mark-n-post): two newly-built
screens were fully implemented, fully tested, present in the router table — and
unreachable by any user, because a dead-tab placeholder (`SOON_TABS`) hid the entry
point. The test-writer had inherited a stale route-membership test from an earlier
cycle, the arbiter's seam check confirmed `<Route>` membership only, and **the whole
internal chain agreed on the same broken state** — the one defect class across three
production runs that only the external codex pass caught. The bar these cases hold:
membership proves registration; only interaction proves reachability.

## How to run a case
1. In a scratch repo, lay out the **repo fixture** (router + tab bar + test harness
   as described).
2. Run the pipeline step the case names; read the produced artifact (manifest,
   dispatch, verdict, or test).
3. Score against **Pass criteria**. A case fails if a `user-reachable` seam greens on
   membership alone, or if an `import-only` seam is blocked for lacking UI proof it
   never claimed.

---

### R1 — Route exists, tab hidden → must NOT be green
**Setup:** slice manifest marks the new `StorageScreen` seam `user-reachable`. The
assembled tree registers `/storage` in the router, but the tab bar renders from a
`VISIBLE_TABS` list that filters `storage` out (a `SOON_TABS` placeholder holds its
slot). The repo has a component test harness (e.g. Testing Library). The suite's only
reachability assertion is `expect(routes).toContainEqual({path: "/storage", …})`.
**Expected:** the arbiter refuses green. Route-membership is explicitly insufficient
for a `user-reachable` seam; the missing/failing interaction path (no tab to click →
destination content never appears) is classified — hidden entry affordance →
**code-fault** (entry point dead), stale membership-only coverage → **test-fault**
(the test-writer must author the interaction test). Either classification must cite
evidence; "both tracks agree" is not evidence of reachability.
**Pass criteria:** no green while the tab is hidden; the fault routing names the dead
entry affordance or the stale test explicitly.

### R2 — Clickable tab navigates, destination content appears → acceptable
**Setup:** same manifest and harness; the tab bar now renders a real `Storage` tab.
The suite contains an interaction test: render the shell, `click` the `Storage` tab,
assert the storage screen's distinctive content appears (not merely that the URL
changed or a route object exists).
**Expected:** the arbiter accepts this as user-reachability proof for the seam (all
other gates unchanged) and does not demand more than the spec claimed — no e2e
browser matrix, no visual framework; the render-harness interaction is the declared
bar.
**Pass criteria:** green is reachable with exactly this proof; the arbiter's verdict
cites the interaction test as the reachability evidence.

### R3 — Import-only seam → smoke import IS enough
**Setup:** the manifest marks a shared `formatBytes` helper seam
`internal/import-only` (no user-facing claim anywhere in the spec). The suite has
unit tests + the arbiter's compilable smoke-import from the named entry point. No
interaction test exists.
**Expected:** the arbiter greens on the smoke-import + tests; it must **not** demand
click-through proof, a route, or a screen for a seam the spec never declared
user-reachable (over-blocking here is the same class of error as under-blocking R1).
**Pass criteria:** no reachability objection is raised; the seam check stays at
import/type-narrowness level.

### R4 — Stale inherited test where the spec demands reachability → test-fault
**Setup:** an earlier cycle of the epic left `expect(routes).toContain("/storage")`
in the tree. This slice's spec/manifest upgrades the seam to `user-reachable`. The
test-writer's fresh suite keeps the inherited membership test as the only coverage
for the seam (the exact live-run S2 shape). Implementation-side the tab is actually
clickable — the code is fine.
**Expected:** the test-writer contract already forbids this (write a fresh
interaction test; match the test to the seam class); if it reaches the arbiter, the
verdict is **test-fault** with the NL analysis naming the missing interaction proof —
not a code-fault against a working implementation, and not a green.
**Pass criteria:** the stale membership test is not accepted as reachability
coverage; the routing targets the test side.

### R5 — No render/interaction harness in the repo → recorded limitation + verifier backstop
**Setup:** the manifest marks a seam `user-reachable`, but the repo has no component
render harness at all (server-templated pages, no DOM test tooling in the validation
contract).
**Expected:** nobody fakes a harness and nobody silently downgrades the seam to
route-registered. The test-writer reports the missing harness as a candidate
spec/validation gap; the arbiter records the limitation explicitly in its verdict
("reachability asserted only via <checked>; no interaction harness available") and
the cross-model verifier's post-green pass is directed to inspect reachability — the
backstop that caught the live defect.
**Pass criteria:** the limitation is recorded in so many words; the verifier round is
told to check reachability; no unqualified green claims user-reachability was proven.
