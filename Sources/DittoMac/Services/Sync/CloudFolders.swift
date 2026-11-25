// CloudFolders.swift — finds the folders that cloud apps already sync on this Mac. No provider API, no OAuth, no tokens:
// DittoMac only writes encrypted files into a folder the user's cloud app uploads (Google Drive for desktop, iCloud Drive,
// Dropbox, OneDrive, Box, pCloud, …).

import AppKit
import DittoCore

struct CloudFolder: Identifiable, Equatable {
    var id: String { url.path }
    let name: String          // "Google Drive (me@example.com) · My Drive"
    let provider: String      // "Google Drive"
    let symbol: String        // SF Symbol
    let url: URL
}

enum CloudFolders {
    /// Candidate folders that exist right now, best first. Pure file-system look-up (no network).
    static func detect(home: URL = URL(fileURLWithPath: NSHomeDirectory()), fileManager fm: FileManager = .default) -> [CloudFolder] {
        var out: [CloudFolder] = []
        func isDir(_ u: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }
        func add(_ name: String, _ provider: String, _ symbol: String, _ url: URL) {
            guard isDir(url), !out.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
            out.append(CloudFolder(name: name, provider: provider, symbol: symbol, url: url))
        }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let entries = ((try? fm.contentsOfDirectory(atPath: storage.path)) ?? []).sorted()
        for e in entries where !e.hasPrefix(".") {
            let url = storage.appendingPathComponent(e, isDirectory: true)
            let lower = e.lowercased()
            let suffix = e.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            if lower.hasPrefix("googledrive") {
                let who = suffix.isEmpty ? "" : " (\(suffix))"
                add("Google Drive\(who) · My Drive", "Google Drive", "externaldrive.badge.icloud", url.appendingPathComponent("My Drive", isDirectory: true))
                add("Google Drive\(who) · top level", "Google Drive", "externaldrive.badge.icloud", url)
            } else if lower.hasPrefix("dropbox") {
                add(suffix.isEmpty ? "Dropbox" : "Dropbox (\(suffix))", "Dropbox", "shippingbox", url)
            } else if lower.hasPrefix("onedrive") {
                add(suffix.isEmpty ? "OneDrive" : "OneDrive (\(suffix))", "OneDrive", "cloud", url)
            } else if lower.hasPrefix("box") {
                add(suffix.isEmpty ? "Box" : "Box (\(suffix))", "Box", "archivebox", url)
            } else if lower.hasPrefix("pcloud") {
                add(suffix.isEmpty ? "pCloud" : "pCloud (\(suffix))", "pCloud", "cloud.fill", url)
            } else if lower.hasPrefix("icloud") || lower.hasPrefix("proton") || lower.hasPrefix("nextcloud") || lower.hasPrefix("sync") || lower.hasPrefix("mega") {
                add(e, e.split(separator: "-").first.map(String.init) ?? e, "cloud", url)
            }
        }
        add("iCloud Drive", "iCloud Drive", "icloud", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true))
        // older client layouts
        add("Dropbox", "Dropbox", "shippingbox", home.appendingPathComponent("Dropbox", isDirectory: true))
        add("Google Drive", "Google Drive", "externaldrive.badge.icloud", home.appendingPathComponent("Google Drive", isDirectory: true))
        add("OneDrive", "OneDrive", "cloud", home.appendingPathComponent("OneDrive", isDirectory: true))
        add("Box", "Box", "archivebox", home.appendingPathComponent("Box", isDirectory: true))
        return out
    }

    /// "Choose folder…" panel. Calls back on the main thread with the chosen folder, or nil if cancelled.
    @MainActor
    static func chooseFolder(completion: @escaping (URL?) -> Void) {
        let p = NSOpenPanel()
        p.title = "Choose a folder your cloud app syncs"
        p.message = "DittoMac creates a “\(SyncFolder.directoryName)” folder inside it and stores only encrypted files there."
        p.prompt = "Choose"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        completion(p.runModal() == .OK ? p.url : nil)
    }
}
