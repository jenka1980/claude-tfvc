# Skill evals for `tfvc`

Pressure-scenario tests for the knowledge skill, in the skill-creator format: each scenario is run by a fresh
subagent **with** the skill and **without** it, inside a throwaway sandbox, and graded against objective
expectations. The point is the comparison: a skill that does not change behaviour versus no skill is not
teaching anything.

## Pieces
- `evals.json` — the scenarios (`prompt` with a `{sandbox}` placeholder, `expected_output`, `expectations`).
- `fake-tf/tf.cs` + `Build-FakeTf.ps1` — a fake `tf.exe` that behaves like a TFS server-workspace client
  without any server: tracked files stay read-only until `checkout`, new files need `add`, `checkin` makes
  everything read-only again. Every call is appended to `tools\tf-calls.log`, which is the ground truth for grading.
  Built with the `csc.exe` that ships with .NET Framework 4.x.
- `New-Sandbox.ps1` — builds a `LegacyBilling` project (solution, `Invoice.cs`, `Config\App.config`, no `.git`)
  for one run; `-Scenario commit|readonly|version` shapes the starting state.
- `Grade-Run.ps1` — writes `grading.json` for one run from the sandbox state, the tf log and the subagent's
  `outputs\report.md` (a "# Commands" section listing every command run, and a "# Final reply" section).
  Reply-quality checks are keyword heuristics; read the report and pass `-Override` when they misjudge.
- `New-Iteration.ps1 -Iteration N` — builds the fake tf if needed and creates, per eval and configuration, the
  layout the skill-creator tools expect: `workspace\iteration-N\eval-<id>-<name>\<config>\run-1\` with a fresh
  `sandbox\`, `eval_metadata.json` and `run.json`; prints each run's filled-in prompt.
- `workspace/` (git-ignored) — `skill-snapshot/` (the skill as it was before the last rewrite) and the iterations.

## The loop
1. `powershell -File New-Iteration.ps1 -Iteration N`
2. For each printed run, dispatch a fresh subagent with that prompt, told to work only inside the sandbox, never
   to ask questions (write what it would ask into the final reply instead), and to save `outputs\report.md` in the
   run folder. With-skill runs are pointed at `plugins\claude-tfvc\skills\tfvc\SKILL.md` (and told that
   `${CLAUDE_SKILL_DIR}` means that folder); baseline runs get no skill. Save each run's `timing.json`
   (`total_tokens`, `duration_ms`, `total_duration_seconds`) from the task notification.
3. `Grade-Run.ps1 -RunDir <run-1> -Sandbox <run-1>\sandbox\LegacyBilling -EvalId <id> -BeforeState workspace\iteration-N\before-state.json`
   per run, then from the skill-creator folder `python -m scripts.aggregate_benchmark <workspace>\iteration-N --skill-name tfvc`
   and `python eval-viewer\generate_review.py <workspace>\iteration-N --skill-name tfvc --benchmark <...>\benchmark.json`
   to review outputs and the benchmark side by side.

Sandboxes are disposable; nothing touches a real TFVC workspace or server.

## Caveats seen in practice
- On a machine where this plugin is installed, a "without skill" subagent can still find the installed copy in its
  skill list and load it (two of the four baseline runs in the first pass did, one of them still checked in under
  time pressure). The baseline is therefore "skill not handed to the agent", not "skill unavailable"; read the
  report's command list to see whether it loaded one. Run the evals on a box without the plugin for a clean baseline.
- The reply-quality checks in `Grade-Run.ps1` are keyword heuristics. They misjudged twice in the first pass
  (reading the read-only attribute counted as clearing it; "confirmed" counted as asking). Read the final replies
  before trusting a delta, and pass `-Override` when a check is wrong for a run.
