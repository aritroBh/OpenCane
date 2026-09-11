# CaneKit — Claude Code project rules

Read `AGENTS.md` first (hard rules, layout, commands, deliberate oddities), then
`docs/CODE_REFERENCE.md` for the file/type/function map. Both override anything you infer from the code.

- Swift 6 strict concurrency, main-actor default; iOS 26 APIs only; no third-party packages.
- Decisions with numbers live in `ios/Logic` with tests; run `cd ios && make test` before every commit.
- Simulator target is the iPhone 17 Pro Max on iOS 27 (`make sim17` once). Demo runs untethered on the phone.
- Keys only in git-ignored `ios/CaneKit/Resources/Secrets.plist`. Never regenerate `CaneKit.xcodeproj`
  unless `ios/project.yml` changed.
- To find where something lives or what touches it, ask the graph first: `graphify query "<question>"`
  (communities in `graphify-out/GRAPH_REPORT.md`); `graphify update .` after code changes.
- Automated runs are silent: the app mutes itself under `CANEKIT_MUTE=1` / `CANEKIT_UITEST=1`.
- **Engineering bar (AGENTS.md → "How we engineer"):** evidence before claims; test first in
  `ios/Logic` for every numeric rule (a bug fix starts with a failing test); after every chunk run an
  adversarial multi-agent review **and** Muse **and** Antigravity (on a repo copy), verify each
  finding yourself, fix or reject with evidence; verify end to end silently (`make test sim uitest e2e`);
  new untuned features ship off by default; document every file and function in the same commit.
- Muse-review the diff before committing; commit messages end with `test on device: …`; add a
  `CHANGELOG.md` entry; tick `docs/todo.md`.
