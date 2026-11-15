# Changelog

Details for each version are in [docs/releases](docs/releases) and [GitHub Releases](https://github.com/eddieee-git/mac-app-gitty/releases). 한국어: [CHANGELOG.md](CHANGELOG.md)

## 0.2.2 (2026-11-15)

- Updates use the updater shared by all five apps: separate switches for automatic checks (on by default) and automatic installs (off by default), plus **Check Now** in Settings
- Stronger update checks: installs only after the signature, SHA-256, bundle ID, version, and code signature are verified
- Finds the latest version from the releases page even when GitHub's rate limit (403/429) is hit
- About section in Settings: version, GitHub, changelog, problem reports, and other apps
- Friendlier tone in Korean messages

## 0.2.1 (2026-11-14)

- Fixed update checks failing with GitHub's rate limit (403): falls back to another way of finding the latest version

## 0.2.0 (2026-11-14)

- Middle copy buttons (▶ ◀) and folder matching (⇄)
- Tabs (⌘T) and new windows (⌘N), list or icon view per pane, remembered tree layout and sizes
- File status badges, View on GitHub and Copy Link
- Keyboard: switch panes, open, delete, type to jump to a name
- Cancel long operations
- English interface
- Asks before uploading files that look secret and before uploading to a public repository; the log file can be turned off
- Folder changes show right away, faster first clone and large folder lists, large files fetched only when needed

## 0.1.6 (2026-11-13)

- Fixed folders that are themselves shortcuts (symbolic links) showing as empty
- Google Drive's My Drive is shown as one real folder

## 0.1.5 (2026-11-13)

- Fixed My Drive showing as empty with Google Drive mirroring
- Shows the reason when a folder can't be read

## 0.1.4 (2026-11-13)

- Fixed Google Drive's My Drive not showing; added to the top of Locations and to Favorites

## 0.1.3 (2026-11-13)

- Conflict resolution: mine / theirs / keep both, per file
- Quick Look with Space

## 0.1.2 (2026-11-13)

- Automatic updates (Ed25519 signature check)
- Undo the last Git action (⌥⌘Z), file history
- List sorting, first-run guide
- Commits only changed files; batches consecutive actions into one push
- Fixed freezes on Google Drive and network folders; tokens are redacted in the log

## 0.1.1 (2026-11-13)

- Fixed drag-and-drop upload and opening recent repositories
- Explorer-style layout with folder trees, Finder-style favorites and locations
- Drop onto folders, progress, search, progress log and activity log
- Files over 100 MB go through Git LFS; automatic sync
- App icon

## 0.1.0 (2026-11-13)

- First version: drag between two panes to commit and push
