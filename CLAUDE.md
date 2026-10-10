# CLAUDE.md

Lanes is a read-only, native macOS viewer for Git history (Swift + AppKit, no dependencies, no Xcode project).

## Build and run

- `./build.sh` builds a release binary, then assembles `build/Lanes.app`, adds the icon and ad-hoc signs it.
- `swift build -c release` alone is enough to check that the code compiles.
- The app icon is drawn by `scripts/make-icon.swift`; `build.sh` regenerates it on every build. Don't commit image files for it.
- Swift language mode is 5 (`swift-tools-version:5.9`). `main.swift` wraps app startup in `MainActor.assumeIsolated`.

## Workflow

- One branch per issue, cut from `main`. Open a PR to `main`; merge with **squash only** (the repo only allows squash, and deletes the head branch on merge).
- PRs get AI review from Codex (`@codex review`) and Copilot. For each finding: check it against the code, reproduce it when possible, fix it, then reply in the thread with the fixing commit hash and how it was verified. Say so when a finding is wrong instead of changing code.
- Each re-review tends to surface narrower edge cases. Once real issues are fixed, merge and track further findings as issues rather than looping.
- Commits, PRs, README and code comments are in English. UI strings are written in English with `String(localized:)`, and their Japanese translations live in `Localization/ja.lproj/Localizable.strings` (`build.sh` copies it into the app). Add every new UI string to that file.

## Conventions in the code

- **Run git only through `Git.run`.** It sets `core.quotepath=false` and `log.showSignature=false`, and `run(_:in:limit:)` stops reading (and kills git) past a byte limit. Use the limit for anything whose output can be huge, such as diffs.
- **Never run git on the main thread.** Git can block indefinitely, e.g. on a macOS privacy prompt when its config lives in a protected or cloud-synced folder, and that would freeze the UI. Use `Task.detached` and come back with `MainActor.run`.
- **Guard every async result with a generation token** (`loadToken`, `detailToken`, `textToken`, `prToken`), so that a slower, older request can't overwrite a newer one. A new async flow gets its own token.
- **Pass file paths to git with `--literal-pathspecs`**, so names like `a*b` or `:(glob)x` aren't treated as patterns.
- **Diff a root commit against the empty tree from `git hash-object -t tree /dev/null`**, not a hard-coded SHA-1 ID, so SHA-256 repositories work.
- **Add `HEAD` to `git log` only if it resolves.** An unborn HEAD makes the whole command fail.
- **Pull requests come from the `gh` CLI** (`GitHub.pullRequests`), fetched apart from the history so the graph never waits on the network. When `gh` is missing, signed out, or the repository isn't on GitHub, show no PRs rather than an error. Like git, never run it on the main thread.
- The only write Lanes makes anywhere is the "@codex review" PR comment (`GitHub.comment`), posted after a confirmation sheet.
- `GraphLayout.compute` expects commits ordered children before parents (`--date-order`).

## Verifying changes

- Screen capture is usually unavailable to the agent. To check the UI, temporarily add a hook that renders the window with `cacheDisplay(in:to:)` to a PNG and quits, run the binary with a test repository, inspect the image, then remove the hook before committing.
- To test git-level logic without the UI, compile `Sources/Lanes/Git.swift` together with a throwaway `main.swift` outside the repo using `swiftc`.
- Build test repositories outside the repo, covering branches and merges, tags, remote refs, renames, non-ASCII file names, SHA-256 repos (`git init --object-format=sha256`), unborn branches and detached HEAD as relevant.
- When launching via `open -a`, set `--env XDG_CONFIG_HOME=<empty dir>` if git's config would trigger a privacy prompt.

## Background

- The name "Lanes" is also used by an unrelated AI-agent app (lanes.sh). This was considered, and the name was kept on purpose.
- Features deliberately left out so far: actions that change the repo (checkout etc.), auto-refresh, stashes, uncommitted changes, and more than 20,000 commits.
