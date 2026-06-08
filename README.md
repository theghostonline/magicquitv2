# MagicQuit

MagicQuit is a macOS menu bar app that automatically quits regular apps after they have been inactive for a chosen amount of time.

This fork keeps MagicQuit's original "watch all currently open apps" workflow, but adds finer timeout control and a persistent exclusion list so you can protect apps you always want left alone.

## Fork changes

- Idle timeout can now be set as low as 1 minute instead of being limited to whole hours.
- Existing hour-based preferences migrate automatically to the new minute-based setting.
- The menu bar popover now includes an Exclusions section.
- Use the `+` button to choose apps from Finder that MagicQuit should always ignore.
- Use the `-` button to remove the selected app from the exclusion list.
- Exclusions are stored by bundle identifier, so they persist across launches.

## How it works

MagicQuit tracks regular running apps and resets an app's idle timer when that app is frontmost. When an app has been inactive longer than the configured timeout, MagicQuit asks macOS to terminate it.

The popover still lets you temporarily disable quitting for currently running apps with the per-app checkbox. The new Exclusions section is for permanent "never quit this app" choices.

## Build

Requirements:

- macOS 13 or later
- Xcode 26.5 or compatible

Build from the command line:

```sh
xcodebuild -scheme MagicQuit -project MagicQuit.xcodeproj -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

For normal day-to-day use, open `MagicQuit.xcodeproj` in Xcode and run the `MagicQuit` scheme.
