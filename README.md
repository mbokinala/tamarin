<div align="center">
  <img src="Tamarin/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" width="128" height="128" alt="Tamarin app icon">

# Tamarin

Swing between (work)trees

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://github.com/mbokinala/tamarin)
[![Swift 5](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](https://www.swift.org/)

</div>

![Tamarin showing a repository, its worktrees, and an embedded terminal](docs/images/tamarin-worktrees.png)

![Tamarin showing isolated terminal tabs for a feature worktree](docs/images/tamarin-terminals.png)

## Features

- Add repositories and browse their registered worktrees in one sidebar.
- Create worktrees from local or remote branches.
- Open multiple [Ghostty](https://github.com/ghostty-org/ghostty)-based terminal tabs for each worktree.
- Switch worktrees with the keyboard while terminal sessions stay open.
- Set a worktree directory and a setup script for each repository.
- Remove linked worktrees with safeguards for primary checkouts, open terminals, and uncommitted files.

## Installation

Tamarin requires macOS 14 or later and Git at `/usr/bin/git`.

Tamarin does not publish binary releases yet. Build the app from source.

## Build from source

1. Clone this repository.
2. Open `Tamarin.xcodeproj` in Xcode.
3. Wait for Xcode to resolve the Swift package dependencies.
4. Select the Tamarin scheme.
5. Build and run the app.
