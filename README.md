# Lanes

A lightweight, native macOS viewer for Git history — the commit graph from VS Code's Git Graph extension, as a standalone app.

Every commit's message, refs, date, author and hash are shown in the list at all times; no hovering required.

- Commit graph with colored lanes, merges and branch/tag labels
- Click a commit to see its message, author, committer and parents, and the lines added and deleted in each changed file
- Click a file to see its diff
- GitHub pull requests on the graph: a `#N` badge on each PR's commit, colored by state, with approval, unresolved review threads and a blue dot for new reviews or comments you haven't opened; select it to read the reviews and comments, or to ask Codex for a review on an open PR (needs the [GitHub CLI](https://cli.github.com), signed in)
- A daily GitHub activity timeline across repositories, with a fixed 24-hour scale, action counts, and links to GitHub
- Each repository in its own tab (⌘1–⌘9 switch tabs); tabs can be moved into separate windows
- Written in Swift with AppKit only — no Electron, no dependencies

Lanes is read-only for now: it does not checkout, commit or modify your repository. The one thing it writes is the “@codex review” comment, posted on GitHub after you confirm.

## Requirements

- macOS 26 or later
- Xcode or the Xcode Command Line Tools (Swift 6.2+)

## Build

```sh
./build.sh
```

This produces `build/Lanes.app`. `./build.sh --install` also copies it to `~/Applications`.

## Usage

- Launch the app and choose a repository folder (⌘O). Each repository opens in a new tab, and the windows and tabs that were open, with their positions and sizes, come back on the next launch.
- From a terminal: `open -a Lanes .`
- ⌘R reloads the history and pull requests (e.g. after committing from the terminal, or to check for new reviews).
- ⌘+ / ⌘− / ⌘0 make the text bigger, smaller or back to the default size, in every window.

The most recent 20,000 commits across all local branches, remote branches and tags are shown.

## GitHub activity

Open **View → GitHub Activity** (⇧⌘A). The timeline starts with today and uses your Mac’s time zone. Use the arrow buttons to browse recent days and ⌘R to refresh. The timeline on the left uses a fixed 00:00–24:00 scale. Each dot marks an event at its local time. The event stream on the right scrolls independently and links to GitHub. Select an hour in the chart to jump to the corresponding events. The summary counts issues, pull requests, reviews, comments, and pushes. Each push counts as one event.

The activity window uses the active GitHub.com account in the [GitHub CLI](https://cli.github.com). To connect an account, run `gh auth login --hostname github.com` in Terminal, then reload the window. Private activity depends on the CLI credentials’ access. GitHub’s [Events API](https://docs.github.com/en/rest/activity/events) returns up to 300 events from the past 30 days, with a delay of up to six hours.


## License

[MIT](LICENSE)
