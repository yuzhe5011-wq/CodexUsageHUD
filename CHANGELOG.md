# Changelog

## Unreleased

- Prevented duplicate Windows and macOS HUD instances across launch directories; locks release on exit or process termination.

- Added public-repository license, security guidance, contribution notes, and issue templates.
- Added Windows release packaging and GitHub Actions validation/build workflows.
- Synchronized macOS refresh and empty-response behavior with Windows.
- Hardened Windows Codex command discovery by validating `--version` and `app-server --help`.

## 2.0.0

- Added the Windows PowerShell/WPF HUD and tray controls.
- Added read-only `codex app-server` rate-limit integration.
- Added reset-credit count and earliest-expiry display when provided.
- Added last-successful-value behavior for refresh failures and empty payloads.
- Added the macOS native menu-bar and floating-capsule source package.
