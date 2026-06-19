---
name: domain-backend
description: Backend specialization — detect the project's real test/lint/build commands and follow server-side test and code conventions.
---

# Domain: Backend

Stack-adaptive conventions for server-side slices. **Detect the toolchain from the repo; never assume.** Prefer the commands the spec or a project validation contract names over anything you guess.

## Detect the toolchain (first match wins)
- `package.json` → Node/TS: test `npm test` / `pnpm test` (`vitest.config*` → Vitest, `jest.config*` → Jest); types `tsc --noEmit`; lint `eslint`.
- `pyproject.toml` / `requirements.txt` → Python: test `pytest -q`; types `mypy`; lint `ruff` (or `flake8`).
- `go.mod` → Go: test `go test ./...`; vet `go vet`; build `go build ./...`.
- `Cargo.toml` → Rust: test `cargo test`; lint `cargo clippy`; build `cargo build`.
- `Makefile` / `justfile` → use the declared targets.
- DB present (`prisma/schema.prisma`, migrations, `docker-compose*.yml`) → tests that touch the DB use an **isolated test DB** (spin up / migrate / tear down); never the dev DB.
- If no toolchain is discoverable, report a spec-gap rather than inventing commands.

## Provisioning (a fresh worktree lacks gitignored deps)
A track worktree is a clean checkout — no `node_modules`, no generated clients. For the contract's Provisioning step, surface the cheapest correct option: prefer **symlinking** the main checkout's deps (`ln -s <repo>/node_modules node_modules`) over a fresh install, and list every **codegen** the build needs (`prisma generate`, protobuf/GraphQL). If a done-gate fails on a missing module or an undefined generated symbol, suspect missing provisioning before you suspect the code.

## Backend testing conventions
- Prefer **real behavior** over mocks; mock only true externals (network, clock, third-party APIs) and mock them **completely** (mirror the real response shape — partial mocks fail silently).
- Cover the unhappy paths the spec names: validation errors, auth failures, boundary values, idempotency/duplicates.
- Test *your* behavior through the public entry point (handler/service), not framework internals.
- Per-test isolation; clean up via test utilities, never via test-only methods bolted onto production classes.

## Code conventions
- Keep handlers thin; put spec'd logic where the spec says it lives. No hidden I/O on import. Fail loudly on spec'd error conditions.
