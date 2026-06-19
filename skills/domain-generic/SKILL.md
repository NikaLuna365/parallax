---
name: domain-generic
description: Language-agnostic fallback specialization for slices that are neither clearly backend nor frontend (libraries, CLIs, scripts, glue).
---

# Domain: Generic

The fallback when a slice isn't specifically backend or frontend (a library, CLI, data transform, glue code). **Detect the toolchain from the repo; never assume.** Prefer the commands the spec or a project validation contract names over guesses.

## Detect the toolchain
- Inspect manifests (`package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Makefile`, `justfile`) for declared test / lint / build commands.
- Honor any commands the spec or README states explicitly — those win over guesses.
- If no toolchain is discoverable, report it as a spec-gap rather than inventing commands.

## Provisioning (a fresh worktree lacks gitignored deps)
A track worktree is a clean checkout, so anything gitignored (dependency dirs, generated code) is absent. For the contract's Provisioning step, name the cheapest correct way to supply them — symlink an existing dependency dir when the stack allows, else install from the lockfile — plus any codegen the build needs. Suspect missing provisioning before the code when a gate fails on a missing module.

## Conventions
- Test the **public contract** of the unit (inputs → outputs, the error conditions the spec names), not internal helpers.
- Pure functions: assert on return values and raised errors; avoid mocks where the logic is pure.
- Keep the implementation minimal and dependency-light; add only what the spec requires.
