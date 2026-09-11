# CaneKit — Claude Code project rules

Read `AGENTS.md` first (hard rules, layout, commands, deliberate oddities), then
`docs/CODE_REFERENCE.md` for the file/type/function map. Both override anything you infer from the code.

- Swift 6 strict concurrency, main-actor default; iOS 26 APIs only; no third-party packages.
- Decisions with numbers live in `ios/Logic` with tests; run `cd ios && make test` before every commit.
- Simulator target is the iPhone 17 Pro Max on iOS 27 (`make sim17` once). Demo runs untethered on the phone.
- Keys only in git-ignored `ios/CaneKit/Resources/Secrets.plist`. Never regenerate `CaneKit.xcodeproj`
  unless `ios/project.yml` changed.
- Muse-review the diff before committing; commit messages end with `test on device: …`; add a
  `CHANGELOG.md` entry; tick `docs/todo.md`.
