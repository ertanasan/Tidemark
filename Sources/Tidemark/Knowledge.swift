import SwiftUI

/// What a person should do about a folder that grew.
enum Safety {
    case safe, redownload, elsewhere, keep, unknown

    var label: String {
        switch self {
        case .safe: return "Safe to delete"
        case .redownload: return "Re-downloads when needed"
        case .elsewhere: return "Remove another way"
        case .keep: return "Keep"
        case .unknown: return "Check first"
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .redownload: return "arrow.down.circle.fill"
        case .elsewhere: return "arrow.turn.up.right"
        case .keep: return "hand.raised.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .safe: return .green
        case .redownload: return .teal
        case .elsewhere: return .orange
        case .keep: return .red
        case .unknown: return .gray
        }
    }

    /// Position when groups are listed: what you can act on first.
    var order: Int {
        switch self {
        case .safe: return 0
        case .redownload: return 1
        case .elsewhere: return 2
        case .unknown: return 3
        case .keep: return 4
        }
    }

    /// What the label means for the person reading it.
    var meaning: String {
        switch self {
        case .safe: return "Nothing is lost: the app or tool recreates these on its own. Move them to the Trash to free the space."
        case .redownload: return "You can delete these; they are downloaded again the next time they're needed, which may take a while."
        case .elsewhere: return "Don't delete these by hand. Select a folder to see the right way to remove it, such as from inside the app that owns it."
        case .unknown: return "Tidemark doesn't recognise these. Open each in Finder and check what it is before deleting."
        case .keep: return "Your own data, or part of an app or macOS. Deleting it could lose something or break things."
        }
    }

    /// Deleting the folder directly is a reasonable thing to offer.
    var deletable: Bool { self == .safe || self == .redownload }
}

struct Classification {
    /// The app or tool the space belongs to; the grouping key.
    let app: String
    /// One line on what the folder is.
    let what: String
    let safety: Safety
    /// What to do about it, including where to delete it when not here.
    let advice: String
}

/// Built-in knowledge of well-known folders. The first matching rule wins, so specific rules
/// come before general ones.
enum Knowledge {
    private enum Match {
        /// The path is this folder or inside it. A leading `~/` means the home folder.
        case under(String)
        /// The path contains this text.
        case has(String)
        /// One of the path's components is exactly this.
        case part(String)
    }

    private struct Rule {
        let matches: [Match]
        let app: String
        let safety: Safety
        let what: String
        let advice: String
    }

    private static func r(_ matches: Match..., app: String, _ safety: Safety, _ what: String, _ advice: String) -> Rule {
        Rule(matches: matches, app: app, safety: safety, what: what, advice: advice)
    }

    private static let home = NSHomeDirectory()

    private static let rules: [Rule] = [
        // MARK: Xcode
        r(.has("SimulatorRuntime"), .has("CoreSimulator/Profiles"), app: "Xcode", .elsewhere,
          "iOS Simulator runtime",
          "A simulator version Xcode installed. Remove the ones you don't use in Xcode ▸ Settings ▸ Components. Deleting files by hand breaks them."),
        r(.has("MetalToolchain"), app: "Xcode", .elsewhere, "Metal shader toolchain",
          "Downloaded for Xcode. Remove it in Xcode ▸ Settings ▸ Components; Xcode downloads it again if a project needs it."),
        r(.has("AppleDeveloperDocumentation"), app: "Xcode", .keep, "Offline developer documentation",
          "Managed by macOS and Xcode. Don't delete it by hand."),
        r(.part("DerivedData"), app: "Xcode", .safe, "Xcode build cache",
          "Xcode rebuilds it on the next build, which is slower once. Delete it with Xcode closed."),
        r(.has("Xcode/Archives"), app: "Xcode", .elsewhere, "Archived app builds",
          "Keep archives of versions you've shipped; Xcode needs them to read crash reports. Remove old ones in Xcode ▸ Window ▸ Organizer."),
        r(.has("DeviceSupport"), app: "Xcode", .redownload, "Debug symbols from your devices",
          "Xcode copies them again, taking a few minutes, the next time you connect that device."),
        r(.has("CoreSimulator/Devices"), app: "Xcode", .redownload, "Simulated iPhones and iPads with their apps",
          "Each folder is one simulator device with its test apps and data. Xcode can create the device again when you need it, but whatever was installed on it is lost. If Xcode still lists the device afterwards, run “xcrun simctl delete <UDID>” or remove it in Xcode ▸ Window ▸ Devices and Simulators."),
        r(.has("CoreSimulator/Caches"), app: "Xcode", .safe, "Simulator cache", "Xcode recreates it as needed."),
        r(.has("CoreDevice"), app: "Xcode", .safe, "Cache of apps installed on devices",
          "Xcode keeps these copies to speed up installs and recreates them as needed."),

        // MARK: Project build output
        r(.part(".build"), .part("build"), app: "Build output", .safe, "Build output of one of your projects",
          "Recreated by the next build. Check it holds no release you haven't saved elsewhere."),
        r(.part("node_modules"), app: "Node.js", .redownload, "Installed JavaScript packages",
          "“npm install” (or your package manager) restores them from the project's package list."),
        r(.has("/clang/ModuleCache"), .part("ModuleCache"), app: "Compiler caches", .safe, "Compiler cache",
          "Compilers recreate it as needed."),

        // MARK: Developer tools
        r(.has("/.nuget/packages"), app: ".NET", .redownload, "NuGet packages", "Restored automatically on the next build."),
        r(.has("/ms-playwright"), app: "Playwright", .redownload, "Browsers downloaded for testing",
          "“npx playwright install” downloads them again."),
        r(.under("~/.cache/huggingface"), app: "Hugging Face", .redownload, "Downloaded AI models",
          "Downloaded again when a program asks for them; large models can take a while."),
        r(.under("~/Library/Caches/pip"), .under("~/.cache/pip"), app: "Python", .safe, "pip download cache",
          "pip downloads packages again as needed. “pip cache purge” clears it."),
        r(.has("/Python.framework/"), app: "Python", .elsewhere, "Python versions and installed packages",
          "Packages from pip live here. Remove unused ones with “pip uninstall”. To remove an old Python, delete its folder under Python.framework/Versions."),
        r(.has("Caches/Homebrew"), app: "Homebrew", .safe, "Homebrew download cache", "“brew cleanup” clears it."),
        r(.under("/opt/homebrew"), app: "Homebrew", .elsewhere, "Tools installed with Homebrew",
          "Remove tools you don't use with “brew uninstall <name>”; “brew cleanup” removes old versions."),
        r(.has("com.docker.docker"), app: "Docker", .elsewhere, "Docker images and containers",
          "Free it with “docker system prune” or Docker Desktop's clean-up options. Don't delete files by hand."),
        r(.under("~/.npm"), .under("~/.gradle/caches"), .under("~/.cargo/registry"), .under("~/.m2/repository"), .under("~/.cache"),
          app: "Developer caches", .redownload, "Downloaded packages", "Tools download them again when a build needs them."),

        // MARK: Claude
        r(.has("Application Support/Claude/vm_bundles"), .has("Application Support/Claude/claude-code-vm"),
          app: "Claude", .redownload, "Virtual machine for Claude's desktop app",
          "Used to run code in isolation. Claude downloads it again when needed."),
        r(.has("Application Support/Claude/claude-code/"), .has(".local/share/claude/versions"),
          app: "Claude", .redownload, "Downloaded Claude Code versions",
          "The app downloads the version it needs again; older ones are safe to remove."),
        r(.has("Application Support/Claude/Cache"), .has("Application Support/Claude/Code Cache"),
          app: "Claude", .safe, "App cache", "Claude recreates it as needed."),
        r(.under("~/.claude"), app: "Claude", .keep, "Claude Code settings and conversation history",
          "Deleting it loses your past Claude Code sessions and settings."),

        // MARK: VS Code
        r(.has("Application Support/Code/Cache"), .has("Application Support/Code/Code Cache"), .has("Application Support/Code/GPUCache"),
          app: "VS Code", .safe, "Editor cache", "VS Code recreates it as needed."),
        r(.has(".vscode/extensions"), app: "VS Code", .elsewhere, "Installed extensions",
          "Uninstall the ones you don't use from VS Code's Extensions panel."),
        r(.under("~/Library/Application Support/Code"), app: "VS Code", .keep, "Settings, workspaces and extension data",
          "Holds your settings and per-project state. Open the subfolders: the cache folders are disposable, the rest is not."),

        // MARK: Apps and their data
        r(.has(".photoslibrary"), app: "Photos", .elsewhere, "Your Photos library",
          "Manage it inside Photos; deleting files within the library damages it. In Photos ▸ Settings ▸ iCloud, “Optimize Mac Storage” keeps smaller copies on this Mac."),
        r(.has("net.whatsapp.WhatsApp"), app: "WhatsApp", .elsewhere, "Chat media",
          "Clear it from inside WhatsApp; deleting files by hand can leave chats with missing media."),
        r(.has("Application Support/OneDrive"), .has("CloudStorage/OneDrive"), app: "OneDrive", .elsewhere, "OneDrive sync data",
          "Managed by OneDrive. Use “Free up space” on files in OneDrive instead."),
        r(.has("CloudStorage/GoogleDrive"), app: "Google Drive", .elsewhere, "Files cached from Google Drive",
          "In Google Drive's preferences choose “Stream files”, or right-click files in Finder ▸ Offline access ▸ Online only."),
        r(.has("CoreSpotlight"), app: "macOS", .keep, "Spotlight search index",
          "macOS maintains it; no need to touch it."),
        r(.has("group.com.apple.chronod"), app: "macOS", .keep, "Widget data", "Managed by macOS."),

        // MARK: Temporary files and caches
        r(.has("code_sign_clone"), app: "Temporary files", .safe, "Temporary app copy",
          "Made while an app updates or is verified, and normally removed automatically. Safe to delete when that app is closed."),
        r(.under("/private/tmp"), .under("/private/var/folders"), app: "Temporary files", .safe, "Temporary files",
          "Cleared automatically on restart. Safe to delete when the program using them is closed."),
        r(.under("~/Library/Logs"), app: "Logs", .safe, "Log files", "Safe to delete; apps start new ones."),
        r(.under("~/Library/Caches"), .has("Cache_Data"), app: "App caches", .safe, "App cache",
          "Apps recreate caches as needed; the first launch afterwards may be slower."),

        // MARK: macOS
        r(.under("/Library/Updates"), app: "macOS", .elsewhere, "Downloaded macOS update",
          "Install or discard it in System Settings ▸ General ▸ Software Update. macOS removes it after installing."),
        r(.has("cryptexd"), app: "macOS", .keep, "Mounted system image",
          "An Apple component mounted from a disk image. Leave it alone."),
        r(.under("/System"), app: "macOS", .keep, "Part of macOS", "It can't be removed and grows with system updates."),

        // MARK: Your files
        r(.under("~/Downloads"), app: "Downloads", .keep, "Your downloads",
          "Review it yourself: nothing recreates deleted files."),
    ]

    static func classify(_ path: String) -> Classification {
        // Anything inside an installed app belongs to that app.
        if path.hasPrefix("/Applications/") {
            let parts = path.split(separator: "/")
            if parts.count >= 2, parts[1].hasSuffix(".app") {
                return Classification(
                    app: String(parts[1].dropLast(4)), what: "Part of an installed app", safety: .keep,
                    advice: "Updates add new versions, and the app removes old ones, often after a restart. To free this space, uninstall the app by moving it from Applications to the Trash.")
            }
        }
        let parts = Set(path.split(separator: "/").map(String.init))
        for rule in rules where rule.matches.contains(where: { matches($0, path, parts) }) {
            return Classification(app: rule.app, what: rule.what, safety: rule.safety, advice: rule.advice)
        }
        return Classification(app: "Other", what: "Not recognised", safety: .unknown,
                              advice: "Tidemark doesn't know this folder. Open it in Finder and check what it is before deleting.")
    }

    private static func matches(_ m: Match, _ path: String, _ parts: Set<String>) -> Bool {
        switch m {
        case .under(let p):
            let full = p.hasPrefix("~/") ? home + p.dropFirst(1) : p
            return path == full || path.hasPrefix(full + "/")
        case .has(let s): return path.contains(s)
        case .part(let s): return parts.contains(s)
        }
    }

    /// The path with the home folder shortened to ~.
    static func display(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
