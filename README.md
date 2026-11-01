<img src="docs/icon.png" width="128" alt="Tidemark icon">

# Tidemark

A native macOS disk-usage viewer (SwiftUI). Shows every mounted drive, fixed or removable, and the size of each folder. Highlights: [FEATURES.md](FEATURES.md).

- Folder tree with sizes and share-of-parent bars
- Drive list with total / free space
- Tabs: Chart (treemap), Details, Extensions, Largest Files
- **Changes** tab: folders over 1 GB (adjustable) that are new, went past 1 GB, or grew by 1 GB since an earlier scan. A size snapshot is saved after every scan (`~/Library/Application Support/Tidemark/Snapshots`); before the first one exists it lists recently created big folders. Flagged folders get a badge in the tree.
- Optional background scan of the main drive once a day while the Mac is idle and on AC power (File menu), with a notification when folders grow past the limit. Between weekly full scans it only re-reads the folders that changed since the last one (from FSEvents), so it takes seconds instead of minutes
- Move files and folders to the Trash (with confirmation) from the right-click menu
- Toggle between file size and size on disk; choose the display unit
- Warns when Full Disk Access isn't granted
- Finder integration: right-click a folder → Quick Actions (or Services) → **Open in Tidemark**

## Build

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh            # builds build/app.noindex/Tidemark.app
./build.sh --install  # also copies it to /Applications
./build.sh --release  # universal, Developer ID-signed, notarized build/Tidemark.zip to share
```

`--release` needs the notarization credentials stored once with `xcrun notarytool store-credentials tidemark-notary`. The icon is drawn by `scripts/make-icon.swift`; delete `build/AppIcon.icns` to regenerate it.

Open in Xcode with `xed .`. You can also scan a folder at launch: `open build/app.noindex/Tidemark.app --args /some/path`.

`--install` also copies the **Open in Tidemark** Quick Action (`scripts/Open in Tidemark.workflow`) into `~/Library/Services`. If it doesn't show up, enable it in System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders.
