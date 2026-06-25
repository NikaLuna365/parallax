# Evaluation harness v2 (pointer)

Parallax's quality is measured by an **evaluation harness v2** that lives under `bench/`, **outside
the plugin** — it is not part of the runtime and adds **no command**. The plugin's own
`tests/run.sh` only checks that prompt-contracts are present and forbidden things are absent;
harness v2 measures live-LLM outcome quality (false-green, overbuild, wrong-seam, scout/intake
behaviour) and calibrates against external coding/review benchmarks.

See:
- `bench/harness_v2/README.md` — record/fixture/aggregate schemas, static metrics, aggregation, fixtures, adapters.
- `bench/harness_v2/tests/run.sh` — lightweight self-tests for the harness.
- `bench/EXTERNAL_CALIBRATION_v0.35_PLAN.md` / `STATUS.md` — pilot external calibration (currently **PILOT READY — NOT RUN**).

v0.35 is a **measurement release**: it changes **no runtime behaviour** and makes **no benchmark
claim**. It exists so the v0.36 benchmark can run on a stable, reviewable measurement layer with raw
per-run records — not another ad-hoc campaign.
