# Parallax Brief Packet & AI-architect handoff

This reference defines how an upstream **user or AI-architect** hands a feature to
Parallax, and how Parallax answers when a brief isn't ready to build. It is used by
`/parallax:spec --from-doc <brief>` and `/parallax:auto <brief>`. There is **no new
command** — the brief packet is just the recommended shape of the `--from-doc` input.

## The one rule: brief is input, not authority
Parallax accepts a brief as **input**, then applies its own gates anyway. Even when an
AI-architect proposes a solution shape, Parallax still runs the **Existing Affordance
Review** (v0.31), **Architecture Fitness** (v0.32), validation-realism, and the
pre-freeze review before it freezes anything. The goal is to *use* the upstream work,
not to *trust it on its word*. Two honest outcomes only:

1. **Build-ready** → the brief is concrete enough, repo evidence/affordances/fitness/
   validation check out, and Parallax freezes the normal artifacts.
2. **Needs intake resolution** → the brief has a product/behaviour/architecture fork
   that can't be settled from repo evidence; Parallax returns an **Intake Response**
   with blocking questions and does **not** start the build.

## Brief Packet format (the recommended `--from-doc` input)
Unstructured markdown is also accepted — Parallax normalizes it into this same shape.

```markdown
# Parallax Brief Packet

## Problem
<what problem / user value this feature solves>

## Desired behavior
<observable behavior; inputs -> outputs; examples if known>

## Constraints
<business, UX, safety, auth, persistence, performance, compatibility constraints>

## Proposed shape
<optional: AI-architect/user proposal; treated as a HYPOTHESIS, not an instruction>

## Existing evidence
<optional: files/docs/ADRs/commands already found; cite paths if known>

## Open decisions
<known unresolved choices; say who must decide: user / product / engineering / repo evidence>

## Non-goals
<what explicitly must NOT be built>

## Validation hints
<known test/lint/build commands, or "unknown">

## Risk notes
<migrations, data loss, auth/safety boundary, product copy, rollout, backwards compatibility>
```

### Rules
- **`Problem`, `Desired behavior`, `Non-goals` should be present for autonomous intake.**
  Missing sections don't auto-fail interactive mode, but they must be resolved before freeze.
- **`Proposed shape` is never authoritative.** It is a *candidate* to test against repo
  evidence, existing affordances, architecture contracts, and validation seams — and it
  can be **rejected** (e.g. a shallow pass-through service, a speculative adapter with no
  current variation, a UI-only auth check that violates a backend ADR, tests through a
  private helper).
- **`Existing evidence` can speed exploration, but Parallax verifies cited files/commands
  before relying** (open the lines; confirm a seam is really public; confirm a command is
  real per the validation contract). The same rule applies to v0.33 scout evidence.
- **`Open decisions` are triaged, not guessed:**
  - answerable from the repo → Parallax investigates (itself or via v0.33 scouts);
  - a pure engineering shape → Parallax decides and records the rationale in *Resolved assumptions*;
  - a product / user / business / safety fork → **Intake Response / park** (never guessed autonomously).

## Intake Response format (returned when a brief is NOT build-ready)
A compact, upstream-facing response — suitable for an AI-architect that will then ask a human.

```markdown
# Parallax Intake Response

Status: build-ready | needs-clarification | needs-rescope | blocked

Summary:
<one paragraph: what Parallax understood>

Blocking questions:
| id | question | why it blocks | options | recommended default |
|----|----------|---------------|---------|---------------------|
| Q1 | <one concrete question> | <what spec/gate cannot decide> | A / B / custom | <only if safe; otherwise "none"> |

Repo evidence checked:
- `<file>:<line>` / `<command>` / "not checked because ..."

Assumptions Parallax can safely make:
- <mechanical assumptions from repo evidence, with rationale>

Rejected proposed shape, if any:
- <brief proposed X; rejected because existing seam / Architecture Fitness / etc.>

Next action:
<answer Q1..Qn and rerun /parallax:spec --from-doc, or rescope, or abandon>
```

### Requirements
- **At most 5 blocking questions** per response, each **concrete and answerable**.
- **Never ask what the repo can answer** — investigate (or scout) first.
- **Never return style/preference as a blocker.** A question must actually block a frozen spec.
- If a question has a **safe** recommended default, explain why; if not, write
  `recommended default: none` explicitly.
- **No `ignore` / `ship anyway` options.** Intake never offers a way past a real gate;
  a parked product fork is resolved by a human decision, not waved through. (After a run
  parks on a spec-gap, that's `/parallax:resolve` — a different, post-build path.)

## Handoff etiquette (for the upstream AI/user)
- **Facts beat proposals.** Observable requirements, constraints, and non-goals carry more
  weight than "I propose service X" — put the real requirements first.
- **Bounded loop, not endless brainstorm.** One intake pass returns up to 5 blocking
  questions; answer them by **updating the brief packet** and rerunning. If two consecutive
  passes return mostly new blockers of the same size, Parallax recommends **rescope /
  decompose** rather than continuing a broad agent↔agent brainstorm.
- **Same gates after intake.** Once the brief is normalized, everything downstream is the
  ordinary Parallax pipeline: spec, slice manifest, validation contract, pre-freeze review,
  blind tracks, the cross-model verifier, and v0.31 resolution semantics. Intake doesn't
  skip or soften any of it.

## What this is NOT
Not a new command, not an API/MCP endpoint, not a persistent external conversation, and
not a way for an upstream AI to bypass Parallax's gates or to decide blockers/resolution
on Parallax's behalf. It is a documented input shape plus an honest "not build-ready yet"
answer.
