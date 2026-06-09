## Fork changes - 2026-06-08

### Added
- Added a Homebrew cask for installing this fork from the `theghostonline/magicquit` tap.
- Added a persistent Exclusions section to the menu bar popover.
- Added `+` and `-` controls for choosing apps that MagicQuit should always leave open.
- Added persistent exclusion storage by bundle identifier.

### Changed
- Idle time is now configured in minutes, with a 1 minute minimum.
- Existing hour-based idle time preferences migrate to the new minute-based setting.

## Version 1.4 - 2023-12-21

### Improvements
- Apps that should not have been terminated where terminated (e.g. apps that run in the background like Cleanshot X, Bartender or Paste)

## Version 1.3.1 - 2023-08-03

### Bug Fixes
- Apps that should not be closed were sometimes formated bold as if they were closed soon
