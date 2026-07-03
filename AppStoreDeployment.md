# App Store Deployment Checklist

## Project Settings

- Set `DEVELOPMENT_TEAM` to your Apple Developer Team ID in Xcode.
- Replace `PRODUCT_BUNDLE_IDENTIFIER` with the bundle ID registered in App Store Connect.
- Increment `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for every upload.
- Archive the `Release` configuration with the `Any Mac` destination.

## App Store Connect

- Create a macOS app record with the same bundle ID.
- Category: Productivity.
- Privacy: no tracking and no collected data, unless you add analytics or external services later.
- Add screenshots, description, keywords, support URL, and review notes.

## Review Notes

Clipboard is a menu bar clipboard history utility. It stores clipboard text and links locally in the app container, uses the system pasteboard, and provides a global hotkey for showing the clipboard window.

The app may request Accessibility permission when using automatic paste. If App Review asks, explain that this is used only to send Command-V after the user selects a clipboard item.
