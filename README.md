# Task Deck for Codex

Task Deck for Codex is an unofficial native macOS companion for keeping active Codex tasks visible without navigating the full Codex sidebar. It groups tasks by project, highlights work that needs attention, and opens tasks directly in Codex.

> [!WARNING]
> This project is not affiliated with, endorsed by, or supported by OpenAI. It relies on undocumented Codex database, session, and local desktop IPC formats that may change without notice.

## Features

- Console and All Tasks views with search and multi-select filters
- Project grouping, persistent project ordering, and a dedicated Chats group
- Persistent task pins and local title overrides
- Task archiving with undo
- Live task status, elapsed working time, and relative creation time
- Configurable font family and font size
- New-task shortcuts and direct navigation to tasks in Codex
- Automatic refresh from Codex's local task data

## Requirements

- macOS 26 or later
- Xcode 26 with the Swift 6.2 toolchain
- Codex for macOS

## Build and test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
```

For local development, the helper script builds an app bundle, applies ad-hoc signing, and launches it:

```sh
./script/build_and_run.sh
```

Use `--debug` for a debug build or `--build-only` to skip launching. The script is for development only; ad-hoc signing is not suitable for distributing binaries.

## Privacy and local data

Task Deck for Codex makes no network requests. It accesses Codex only through local files, Codex's bundled command-line tool, and local desktop IPC. It reads Codex state locally from:

- `~/.codex/state_5.sqlite`
- `~/.codex/.codex-global-state.json`
- session JSONL files under `~/.codex/sessions/`

Archiving and undo use Codex's bundled command-line tool so Codex moves the session file and updates its state consistently. The companion also sends a local desktop refresh notification when Codex is running. Pins, task-title overrides, project order, and other companion preferences are stored locally in macOS `UserDefaults`.

## Compatibility

Task Deck for Codex relies on undocumented internal Codex database, session, and local desktop IPC formats. A Codex update may change those formats and temporarily break task discovery, status reporting, or immediate sidebar refresh. This project is not affiliated with or supported by OpenAI.

## Release scope

This repository is a source release. Public binary distribution would additionally require a Developer ID build, hardened runtime, signing, and notarization.

## License

[MIT](LICENSE)
