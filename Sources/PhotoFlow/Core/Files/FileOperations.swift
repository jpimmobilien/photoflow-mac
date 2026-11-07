import Foundation
import AppKit

/// Safe file management. Deletion always goes through the macOS Trash (never permanent by default) and every
/// trashed file is logged so it can be restored from PhotoFlow's own Trash view.
enum FileOperations {
    struct Failure: Sendable, Identifiable {
        var id: String { path }
        var path: String
        var message: String
    }

    struct TrashOutcome: Sendable {
        var trashed: [(photoID: Int64, originalPath: String, trashPath: String, size: Int64)]
        var failures: [Failure]
    }

    /// Moves files to the Trash. Uses `FileManager.trashItem`, which behaves exactly like Finder's
    /// "Move to Trash" (files stay recoverable, also via Finder's "Put Back").
    static func moveToTrash(_ photos: [PhotoRecord]) -> TrashOutcome {
        var out = TrashOutcome(trashed: [], failures: [])
        let fm = FileManager.default
        for p in photos {
            guard fm.fileExists(atPath: p.path) else {
                out.failures.append(Failure(path: p.path, message: String(localized: "The file no longer exists at its original location.")))
                continue
            }
            do {
                var resulting: NSURL?
                try fm.trashItem(at: p.url, resultingItemURL: &resulting)
                out.trashed.append((p.id, p.path, (resulting as URL?)?.path ?? "", p.fileSize))
            } catch {
                out.failures.append(Failure(path: p.path, message: explain(error, action: .trash)))
            }
        }
        return out
    }

    /// Restores a file PhotoFlow moved to the Trash back to its original location.
    static func restore(_ entry: TrashEntry) throws -> URL {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: entry.trashPath)
        guard !entry.trashPath.isEmpty, fm.fileExists(atPath: source.path) else {
            throw FileError.message(String(localized: "“\(entry.filename)” is no longer in the Trash (the Trash may have been emptied)."))
        }
        var target = URL(fileURLWithPath: entry.originalPath)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            target = uniqueSibling(target)
        }
        do {
            try fm.moveItem(at: source, to: target)
        } catch {
            throw FileError.message(explain(error, action: .move))
        }
        return target
    }

    static func rename(_ photo: PhotoRecord, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix(".") else {
            throw FileError.message(String(localized: "Please enter a valid file name."))
        }
        var name = trimmed
        let ext = photo.url.pathExtension
        if (name as NSString).pathExtension.lowercased() != ext.lowercased() { name += "." + ext }
        let target = photo.url.deletingLastPathComponent().appendingPathComponent(name)
        guard target.path != photo.path else { return target }
        if FileManager.default.fileExists(atPath: target.path) {
            throw FileError.message(String(localized: "A file named “\(name)” already exists in this folder."))
        }
        do {
            try FileManager.default.moveItem(at: photo.url, to: target)
        } catch {
            throw FileError.message(explain(error, action: .rename))
        }
        return target
    }

    /// Moves or copies photos into a folder. Existing files are never overwritten.
    static func transfer(_ photos: [PhotoRecord], to folder: URL, copy: Bool) -> (done: [(Int64, URL)], failures: [Failure]) {
        var done: [(Int64, URL)] = []
        var failures: [Failure] = []
        let fm = FileManager.default
        for p in photos {
            var target = folder.appendingPathComponent(p.filename)
            if target.standardizedFileURL.path == p.url.standardizedFileURL.path { continue }
            if fm.fileExists(atPath: target.path) { target = uniqueSibling(target) }
            do {
                if copy { try fm.copyItem(at: p.url, to: target) } else { try fm.moveItem(at: p.url, to: target) }
                done.append((p.id, target))
            } catch {
                failures.append(Failure(path: p.path, message: explain(error, action: copy ? .copy : .move)))
            }
        }
        return (done, failures)
    }

    static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func uniqueSibling(_ url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(n))")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            n += 1
        }
        return candidate
    }

    enum Action { case trash, move, copy, rename }

    enum FileError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// Turns Cocoa errors into explanations a non-technical user can act on.
    static func explain(_ error: Error, action: Action) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return String(localized: "PhotoFlow does not have permission to change this file. Check the folder's permissions in Finder (Get Info ▸ Sharing & Permissions) or grant PhotoFlow access in System Settings ▸ Privacy & Security ▸ Files and Folders.")
            case NSFileWriteVolumeReadOnlyError:
                return String(localized: "The disk containing this file is read-only (for example a locked SD card or a network share without write access).")
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return String(localized: "The file no longer exists at its original location.")
            case NSFileWriteOutOfSpaceError:
                return String(localized: "There is not enough free disk space.")
            case NSFileWriteFileExistsError:
                return String(localized: "A file with the same name already exists.")
            case NSFeatureUnsupportedError:
                return String(localized: "This disk does not support the Trash (common for network or FAT-formatted drives). The file was not deleted.")
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) {
            return String(localized: "macOS denied access to this file. Grant PhotoFlow access in System Settings ▸ Privacy & Security ▸ Files and Folders (or Full Disk Access).")
        }
        return ns.localizedDescription
    }
}
