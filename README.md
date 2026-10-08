# Lanes

A lightweight, native macOS viewer for Git history — the commit graph from VS Code's Git Graph extension, as a standalone app.

Every commit's message, refs, date, author and hash are shown in the list at all times; no hovering required.

- Commit graph with colored lanes, merges and branch/tag labels
- Click a commit to see its full message and changed files
- Click a file to see its diff
- Written in Swift with AppKit only — no Electron, no dependencies

Lanes is read-only for now: it does not checkout, commit or modify your repository.

## Requirements

- macOS 13 or later
- Xcode or the Xcode Command Line Tools (Swift 5.9+)

## Build

```sh
./build.sh
```

This produces `build/Lanes.app`. Move it to `/Applications` if you like.

## Usage

- Launch the app and choose a repository folder (⌘O). The last repository is reopened on the next launch.
- From a terminal: `open -a Lanes .`
- ⌘R reloads the history (e.g. after committing from the terminal).

The most recent 20,000 commits across all local branches, remote branches and tags are shown.

## License

[MIT](LICENSE)
