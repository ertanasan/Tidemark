<img src="docs/icon.png" width="128" alt="Tidemark icon">

# Tidemark

**Know where every gigabyte went.**

A native macOS disk-usage viewer (SwiftUI). Shows every mounted drive, fixed or removable, and the size of each folder. Highlights: [FEATURES.md](FEATURES.md).

- Folder tree with sizes and share-of-parent bars
- Drive list with total / free space
- Tabs: Chart (treemap), Details, Extensions, Largest Files
- **Changes** tab: folders over 1 GB (adjustable) that are new, went past 1 GB, or grew by 1 GB since an earlier scan. A size snapshot is saved after every scan (`~/Library/Application Support/Tidemark/Snapshots`); before the first one exists it lists recently created big folders. Flagged folders get a badge in the tree.
- [Silent growth tracking](#silent-growth-tracking): a daily background scan while the Mac is idle, with a notification when folders grow past the limit
- Right-click menu: Show in Finder, Copy Path, and Move to Trash (with confirmation); copy the paths of selected or all folders in a list
- Toggle between file size and size on disk; choose the display unit
- Warns when Full Disk Access isn't granted
- Finder integration: right-click a folder → Quick Actions (or Services) → **Open in Tidemark**

## Silent growth tracking

Disks rarely fill up all at once. A simulator update, a build folder or a cache grows by a few gigabytes at a time until the disk is full. Tidemark watches for that in the background, and you don't need to open it.

> **🔔 3 folders are using more space**\
> New: /Users/you/Library/Developer/CoreSimulator/Caches (+6.1 GB)\
> /Users/you/Library/Containers/com.docker.docker (+2.4 GB)\
> /Users/you/Work/MyApp/.build (+1.3 GB)\
> Total +9.8 GB since 10/30/2026 23:20

**How it stays out of your way**

- **Once a day, only when you're away.** The check runs after 10 minutes with no keyboard or mouse input, and only on AC power. It keeps the Mac awake just long enough to finish.
- **Seconds, not minutes.** Between weekly full scans, it re-reads only the folders that macOS's change log (FSEvents) says changed since the last check.
- **Quiet unless it matters.** You get a notification only when a folder is new, has passed your limit, or grew by at least that much since the previous check. The limit can be 256 MB, 512 MB, 1 GB (default), 5 GB or 10 GB.
- **One click to the answer.** Clicking the notification opens the **Changes** tab, comparing the latest scan with the previous one. Flagged folders get a badge in the tree, ready to inspect or move to the Trash.
- **A history to compare against.** Every scan leaves a size snapshot. All snapshots from the last 48 hours are kept, then one per day for 60 days, so you can compare with any earlier date.

Turn it on from **File → Scan Main Drive Daily When Idle**, or with the toggle in the **Changes** tab. It runs as a small launchd agent that starts Tidemark headlessly, and turning it off removes the agent.

## Download

Get **Tidemark-1.1-macOS.zip** from [Releases](https://github.com/ertanasan/Tidemark/releases/latest), unzip it and drag Tidemark to Applications. It's notarized by Apple and runs on Apple silicon and Intel Macs with macOS 14 or later. For complete results, give it Full Disk Access in System Settings → Privacy & Security. The Finder Quick Action isn't in the download; it comes with `./build.sh --install`.

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
