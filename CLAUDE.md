# CaneKit — Claude Code project rules

Read `AGENTS.md` first (hard rules, layout, commands, deliberate oddities), then
`docs/CODE_REFERENCE.md` for the file/type/function map. Trust them over anything you guess, but the
shipped code is the truth: when a doc and the code disagree, fix the doc in the same commit.

- Swift 6 strict concurrency, main-actor default; iOS 26 APIs only; no third-party packages.
- Decisions with numbers live in `ios/Logic` with tests; run `cd ios && make test` before every commit
  (judge it by its own exit code, never through `| tail`).
- Simulator target is the iPhone 17 Pro Max on iOS 27 (`make sim17` once). Demo runs untethered on the phone.
- Keys only in git-ignored `ios/CaneKit/Resources/Secrets.plist`. Never regenerate `CaneKit.xcodeproj`
  unless `ios/project.yml` or the file list changed.
- To find where something lives or what touches it, ask the graph first: `graphify query "<question>"`
  (communities in `graphify-out/GRAPH_REPORT.md`); `graphify update .` after code changes.
- Automated runs are silent: the app mutes itself under `CANEKIT_MUTE=1` / `CANEKIT_UITEST=1`.
- Measure before tuning a cue: `cd ios && make audit` (`ios/scripts/cue_audit.py` on a trip log; a
  handheld log must not tune a distance). Cue research and plan: `docs/cue_design_v2.md`,
  `docs/todo.md` → "Cue design v2".
- **Deliberate, do not "fix"** (details, why and tests in AGENTS.md → "Steps 34–37 and the rotation
  fix"): flashlight state comes from KVO, never `isTorchActive` read right after setting; Both
  cameras is refused for the whole route and face tracking mid-route; `speech_dispatch` is a separate
  log kind from `speech` (e2e.py asserts on `speech`); obstacle names default off; Detailed + Outdoors
  = today, and Detailed never names walls; two-camera rotation is fixed per camera (back 90, front 0)
  for the portrait-only UI, never one shared angle; a line cut by a warning resumes from its clause,
  a call / Siri / dictation restarts it from its last resume point; the 0.35 s pause between bands
  bumps the generation; "Head height." is never delayed behind a direction.
- **Engineering bar (AGENTS.md → "How we engineer"):** evidence before claims; test first in
  `ios/Logic` for every numeric rule (a bug fix starts with a failing test); after every chunk run an
  adversarial multi-agent review **and** Muse **and** Antigravity (on a repo copy), verify each
  finding yourself, fix or reject with evidence in `CHANGELOG.md`; verify end to end silently
  (`make test sim uitest e2e`); new untuned features ship off by default; document every file and
  function in the same commit.
- Muse-review the plan (large or risky changes) and the diff before committing; commit messages end
  with `test on device: …`; add a `CHANGELOG.md` entry; tick `docs/todo.md`.
