# Changelog

## Unreleased

- **Open sessions** section: one card per open Claude Code session with working/idle status, context window fill, total tokens, last reply size, message count and the last prompt. Cycle with the `‹ ›` arrows or ← / →. Read locally from `~/.claude`; the session list is refreshed every 3 seconds while the popover is open
- Providers whose CLI isn't installed are hidden instead of showing an error, and the popover now sizes itself to what's visible (shorter with only Claude)
- Fixed Claude failing with "Timed out (stage: waitingForBanner)": newer Claude Code versions default the folder-trust prompt to "No, exit". The prompt is now answered correctly, and Claude runs in a stable folder so it is only asked once
- Launch gates can now send a delayed follow-up keystroke (needed for arrow-key selectors)
- Missing `import AppKit` that broke the Xcode build
- Redesigned threshold notifications: severity emoji in the title, the metric as the subtitle, a progress bar plus reset time in the body, a coloured progress-ring thumbnail, and grouping per provider
- Fixed threshold alerts being swallowed when the CLI's reset time wobbled by a minute (e.g. 4:59am ↔ 5:00am), which was treated as a new window and reset the baseline
- Refreshed README screenshots (light, dark and split hero)
- Lowered the minimum macOS version to 12 Monterey (was 14 Sonoma for SwiftPM / `build.sh` builds and 26.2 for the Xcode project), so the app runs on older Macs
- Finder-launched app bundles now bootstrap common CLI paths before running `claude` or `codex`, including Homebrew, native `~/.local/bin` installs, and common Node/version-manager installs (`fnm`, `nvm`, `asdf`, `mise`, `nodenv`, `volta`, `pnpm`, `yarn`, npm global prefixes).

## 1.2

- Calmer violet / amber / coral palette with subtle vertical-gradient progress bars (replaces system green/orange/red); wider bars and body-size detail labels for legibility
- macOS notifications when usage crosses 60% / 80% / 100% per metric
- Reset details now show relative time ("Resets in 4h 30m at 1:30pm …") for time-based windows, in addition to the existing relative-days style
- Metrics carry a stable `resetIdentifier` so the notifier can distinguish a new reset window from usage movement within the same window

## 1.1

- Stacked Claude Code + OpenAI Codex usage in one popover
- `Provider` abstraction holding all provider-specific CLI driving config, making additional CLIs pluggable without rewriting the flow
- Structured parsing of `/usage` and `/status` output into native metrics (percent used, reset times, credits) with raw terminal output as a fallback
- Caching with stale-while-revalidate and a 5-minute background refresh timer
- Timed-flow driving for Codex to work around ratatui's char-by-char cursor positioning
- Adaptive popover styling that follows the system appearance (light/dark)
- Per-provider header links to the web usage pages
- `build.sh` for building and relaunching without Xcode (Command Line Tools only)
- Parser tests

## 1.0.0

Initial release.

- Menu bar app with popover showing Claude Code usage
- Full ANSI color rendering via embedded PTY terminal
- Automatic `/usage` command execution
- Rate limit detection with friendly error screen
- Setup detection when Claude Code is not yet configured
- Click-to-dismiss popover
- Right-click to quit
- Runs as a lightweight menu bar agent (no Dock icon)
