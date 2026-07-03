# Clipboard

A native macOS clipboard manager built in C++ with an Objective-C++ AppKit bridge.

## Current features

- Menu bar app with `Command Shift V` global shortcut.
- Floating, resizable glass-style clipboard window.
- Clipboard history for text, links, files, and images.
- Search and segmented filtering by content type.
- Pin, favorite, delete, clear unpinned history, and copy-back actions.
- Persistent local history in Application Support.
- Native macOS window controls, resizing, minimization, and full-screen support.

## Build

```sh
xcodebuild -project ClipboardGlassCpp.xcodeproj -scheme "Clipboard" -configuration Debug -derivedDataPath BuildCpp build
```

The built app will be at:

```text
BuildCpp/Build/Products/Debug/Clipboard.app
```

## Run

Open `ClipboardGlassCpp.xcodeproj` in Xcode and run the `Clipboard` scheme, or launch the built app from Finder.

Because this app monitors the system pasteboard and registers a global hotkey, macOS may ask for permission depending on local privacy settings.
