# WindowBar

WindowBar is a macOS SwiftUI utility that shows a floating edge sidebar with the currently open apps and their windows. It is designed to make it faster to switch between windows, jump across Spaces, and send files to running apps.

![WindowBar screenshot](screenshot.jpg)

## What It Does

- Reveals a floating sidebar when you hover at the screen edge
- Lists running apps and their open windows
- Groups window entries by macOS Space
- Focuses a selected window and switches to its Space when needed
- Lets you hide or quit apps directly from the sidebar
- Supports dropping files onto app icons to open them in that app
- Shows previews of the front app's windows while you cycle them with Command-` (needs window previews enabled)
- Includes settings for:
  - showing only the current Space
  - placing the sidebar on the right edge
  - remembering rail scroll position

## Requirements

- macOS
- Xcode 26 or newer
- Accessibility permission enabled for the app

WindowBar uses macOS accessibility APIs to inspect and focus windows. On first launch, you will likely need to grant permission in:

`System Settings > Privacy & Security > Accessibility`

## Granting Accessibility Permission

The stacked-squares icon next to the "Show only current Space" switch shows the permission state. It is white when Accessibility access is granted and red when it is missing. Without access, the window list can include hidden helper windows listed under "Space Unknown".

WindowBar does not appear in the Accessibility list on its own, so add it manually:

1. Open System Settings from the Apple menu.
2. Click **Privacy & Security** in the sidebar.
3. Scroll down and click **Accessibility**. This is the permission list under Privacy & Security, not the separate Accessibility item for vision and hearing settings.
4. Click the **+** button under the app list and enter your password if asked.
5. Press Command-Shift-G, paste the path to `WindowBar.app`, and press Return.
6. Select WindowBar, click **Open**, and make sure its switch is on.
7. Quit every running copy of WindowBar and launch it again.

When you run from Xcode, the app is in your DerivedData folder. You can find the exact path in Xcode under Product > Show Build Folder in Finder, then `Products/Debug/WindowBar.app`.

You can also jump straight to the right pane from Terminal:

```sh
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

Each copy of the app needs its own entry, so add archived or exported builds separately. If the icon turns red again after a rebuild, remove WindowBar from the list with the **−** button and add it again.

## Window Previews

WindowBar can show a thumbnail of each window in the window list. Previews use ScreenCaptureKit and need Screen Recording permission, in addition to Accessibility.

1. Hover an app in the sidebar and click **Enable window previews** in its window list.
2. Approve the macOS prompt, or turn WindowBar on under `System Settings > Privacy & Security > Screen & System Audio Recording`.
3. Quit and relaunch WindowBar if macOS asks you to.

Previews are captured only for the app you are hovering and are refreshed at most every few seconds. Windows on other Spaces may show no preview, depending on the app. You can turn previews off in Settings.

## Project Structure

```text
WindowBar/
├── WindowBar.xcodeproj
├── WindowBar/
│   ├── AppDelegate.swift
│   ├── ContentView.swift
│   ├── WindowBarApp.swift
│   ├── WindowInventory.swift
│   └── Assets.xcassets
├── WindowBarTests/
└── WindowBarUITests/
```

## Build And Run

1. Open `WindowBar.xcodeproj` in Xcode.
2. Select the `WindowBar` scheme.
3. Build and run the app.
4. Grant Accessibility access as described in [Granting Accessibility Permission](#granting-accessibility-permission).

## Notes

- The app is implemented with SwiftUI and AppKit.
- Window inventory and focus behavior rely on macOS windowing and accessibility APIs.
- The included test targets are mostly placeholders at the moment.
