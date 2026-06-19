---
name: domain-frontend
description: Frontend specialization — detect the project's real test/lint/build commands and follow UI test and code conventions.
---

# Domain: Frontend

Stack-adaptive conventions for UI slices. **Detect the toolchain from the repo; never assume.** Prefer the commands the spec or a project validation contract names over guesses.

## Detect the toolchain
- `package.json` → unit/component tests usually Vitest (`vitest.config*`) or Jest (`jest.config*`) + Testing Library (jsdom); types `tsc --noEmit`; lint `eslint`.
- Identify the framework (React/Vue/Svelte) to pick the right render/query utils.
- `playwright.config.*` → e2e exists; run e2e only at the heavy/full check, never as the fast gate (too slow).
- Unknown? Read the spec/README for declared commands; if still unknown, report a spec-gap.

## Provisioning (a fresh worktree lacks gitignored deps)
A track worktree starts clean — no `node_modules`, no generated types. For the contract's Provisioning step, prefer **symlinking** the main checkout's `node_modules` over a reinstall, and include any **codegen** the app needs (route/type generation, GraphQL codegen). A done-gate that fails on a missing dependency or generated type is usually un-provisioned, not wrong.

## Frontend testing conventions
- Test **user-visible behavior** through accessible queries (roles/labels/text), not implementation details or internal state.
- **Never assert that a mock rendered** (no `getByTestId('*-mock')`). Render the real component; if isolation is unavoidable, assert on the host's behavior, not the mock's presence.
- Cover the states the spec names: loading, empty, error, and the interaction flows (click/submit/keyboard).
- Don't use snapshot-only tests as proof of behavior; assert on what the user can perceive. Never update snapshots to force green.

## Code conventions
- Components driven by the props/state the spec defines; no behavior the spec didn't ask for. Side effects in the spec'd lifecycle hooks, not on import.
