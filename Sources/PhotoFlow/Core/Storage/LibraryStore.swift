import Foundation

/// Persistent photo library (SQLite). Stores references to original files, albums, edit recipes,
/// cached analysis results (hashes, feature prints), the app-managed trash log and export history.
final class LibraryStore: @unchecked Sendable {
    let db: Database
    let directory: URL

    static func defaultDirectory() -> URL {
        // Isolated libraries for automated UI reviews and tests
        if let custom = ProcessInfo.processInfo.environment["PHOTOFLOW_LIBRARY_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PhotoFlow", isDirectory: true)
    }

    init(directory: URL = LibraryStore.defaultDirectory()) throws {
        self.directory = directory
        db = try Database(url: directory.appendingPathComponent("Library.sqlite"))
        try migrate()
    }

    private func migrate() throws {
        try db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        let stored = try db.query("SELECT value FROM meta WHERE key='schema'") { $0.text(0) }.first ?? "0"
        let version = Int(stored) ?? 0
        if version < 1 {
            try db.transaction { tx in
                try tx.execute("""
                CREATE TABLE IF NOT EXISTS photos (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT NOT NULL UNIQUE,
                    bookmark BLOB,
                    filename TEXT NOT NULL,
                    file_size INTEGER NOT NULL,
                    file_modified REAL NOT NULL,
                    width INTEGER NOT NULL,
                    height INTEGER NOT NULL,
                    uti TEXT NOT NULL,
                    capture_date REAL, creation_date REAL,
                    camera_make TEXT, camera_model TEXT, lens_model TEXT,
                    iso INTEGER, exposure_time REAL, f_number REAL, focal_length REAL,
                    imported_at REAL NOT NULL,
                    edited_at REAL,
                    favorite INTEGER NOT NULL DEFAULT 0,
                    missing INTEGER NOT NULL DEFAULT 0
                )
                """)
                try tx.execute("CREATE INDEX IF NOT EXISTS idx_photos_imported ON photos(imported_at)")
                try tx.execute("CREATE INDEX IF NOT EXISTS idx_photos_size ON photos(file_size)")
                try tx.execute("""
                CREATE TABLE IF NOT EXISTS edits (
                    photo_id INTEGER PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
                    recipe BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
                try tx.execute("CREATE TABLE IF NOT EXISTS albums (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at REAL NOT NULL)")
                try tx.execute("""
                CREATE TABLE IF NOT EXISTS album_photos (
                    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
                    photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                    added_at REAL NOT NULL,
                    PRIMARY KEY (album_id, photo_id)
                )
                """)
                try tx.execute("""
                CREATE TABLE IF NOT EXISTS analysis (
                    photo_id INTEGER PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
                    signature TEXT NOT NULL,
                    sha256 TEXT,
                    ahash INTEGER, dhash INTEGER, phash INTEGER,
                    fp_revision INTEGER, feature BLOB,
                    sharpness REAL, exposure_score REAL, aesthetic REAL, utility INTEGER,
                    updated_at REAL NOT NULL
                )
                """)
                try tx.execute("""
                CREATE TABLE IF NOT EXISTS trash (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    photo_id INTEGER,
                    original_path TEXT NOT NULL,
                    trash_path TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    file_size INTEGER NOT NULL,
                    trashed_at REAL NOT NULL,
                    restored INTEGER NOT NULL DEFAULT 0,
                    snapshot BLOB
                )
                """)
                try tx.execute("""
                CREATE TABLE IF NOT EXISTS exports (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    date REAL NOT NULL, destination TEXT NOT NULL, format TEXT NOT NULL,
                    count INTEGER NOT NULL, failed INTEGER NOT NULL, total_bytes INTEGER NOT NULL, source TEXT NOT NULL
                )
                """)
                try tx.execute("CREATE TABLE IF NOT EXISTS presets (id TEXT PRIMARY KEY, name TEXT NOT NULL, recipe BLOB NOT NULL, adaptive INTEGER NOT NULL, created_at REAL NOT NULL)")
                try tx.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema', '1')")
            }
        }
    }

    // MARK: - Photos

    private static let photoColumns = """
    id, path, bookmark, filename, file_size, file_modified, width, height, uti, capture_date, creation_date,
    camera_make, camera_model, lens_model, iso, exposure_time, f_number, focal_length, imported_at, edited_at, favorite, missing
    """

    private static func photo(_ r: Database.Row) -> PhotoRecord {
        PhotoRecord(
            id: r.int(0), path: r.text(1), bookmark: r.blob(2), filename: r.text(3), fileSize: r.int(4),
            fileModified: r.date(5), width: Int(r.int(6)), height: Int(r.int(7)), uti: r.text(8),
            captureDate: r.dateOrNil(9), creationDate: r.dateOrNil(10), cameraMake: r.textOrNil(11),
            cameraModel: r.textOrNil(12), lensModel: r.textOrNil(13), iso: r.intOrNil(14).map { Int($0) },
            exposureTime: r.doubleOrNil(15), fNumber: r.doubleOrNil(16), focalLength: r.doubleOrNil(17),
            importedAt: r.date(18), editedAt: r.dateOrNil(19), isFavorite: r.bool(20), isMissing: r.bool(21))
    }

    func allPhotos() throws -> [PhotoRecord] {
        try db.query("SELECT \(Self.photoColumns) FROM photos ORDER BY id", map: Self.photo)
    }

    func photo(id: Int64) throws -> PhotoRecord? {
        try db.query("SELECT \(Self.photoColumns) FROM photos WHERE id=?", [.int(id)], map: Self.photo).first
    }

    func knownPaths() throws -> Set<String> {
        Set(try db.query("SELECT path FROM photos") { $0.text(0) })
    }

    /// Inserts new photos (ignoring paths already in the library). Returns the inserted records with IDs.
    func insert(_ photos: [PhotoRecord]) throws -> [PhotoRecord] {
        try db.transaction { tx in
            var out: [PhotoRecord] = []
            for var p in photos {
                try tx.execute("""
                INSERT OR IGNORE INTO photos (path, bookmark, filename, file_size, file_modified, width, height, uti,
                    capture_date, creation_date, camera_make, camera_model, lens_model, iso, exposure_time, f_number,
                    focal_length, imported_at, edited_at, favorite, missing)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [
                    .text(p.path), .init(p.bookmark), .text(p.filename), .int(p.fileSize), .init(p.fileModified),
                    .int(Int64(p.width)), .int(Int64(p.height)), .text(p.uti), .init(p.captureDate), .init(p.creationDate),
                    .init(p.cameraMake), .init(p.cameraModel), .init(p.lensModel), .init(p.iso), .init(p.exposureTime),
                    .init(p.fNumber), .init(p.focalLength), .init(p.importedAt), .init(p.editedAt), .init(p.isFavorite), .init(false)
                ])
                if tx.changes > 0 {
                    let id = try tx.query("SELECT last_insert_rowid()") { $0.int(0) }.first ?? 0
                    p.id = id
                    out.append(p)
                }
            }
            return out
        }
    }

    func updateLocation(id: Int64, path: String, bookmark: Data?) throws {
        try db.execute("UPDATE photos SET path=?, filename=?, bookmark=COALESCE(?, bookmark), missing=0 WHERE id=?",
                       [.text(path), .text((path as NSString).lastPathComponent), .init(bookmark), .int(id)])
    }

    func updateFileInfo(id: Int64, size: Int64, modified: Date, width: Int, height: Int) throws {
        try db.execute("UPDATE photos SET file_size=?, file_modified=?, width=?, height=? WHERE id=?",
                       [.int(size), .init(modified), .int(Int64(width)), .int(Int64(height)), .int(id)])
    }

    func setMissing(_ ids: [Int64], missing: Bool) throws {
        guard !ids.isEmpty else { return }
        try db.transaction { tx in
            for id in ids { try tx.execute("UPDATE photos SET missing=? WHERE id=?", [.init(missing), .int(id)]) }
        }
    }

    func setFavorite(_ ids: [Int64], favorite: Bool) throws {
        try db.transaction { tx in
            for id in ids { try tx.execute("UPDATE photos SET favorite=? WHERE id=?", [.init(favorite), .int(id)]) }
        }
    }

    /// Removes photos from the library only (files on disk are untouched).
    func removePhotos(_ ids: [Int64]) throws {
        try db.transaction { tx in
            for id in ids { try tx.execute("DELETE FROM photos WHERE id=?", [.int(id)]) }
        }
    }

    // MARK: - Edits

    func recipe(for id: Int64) throws -> EditRecipe? {
        try db.query("SELECT recipe FROM edits WHERE photo_id=?", [.int(id)]) { $0.blob(0) }
            .first.flatMap { $0 }.flatMap(EditRecipe.decode)
    }

    func recipes(for ids: [Int64]) throws -> [Int64: EditRecipe] {
        var out: [Int64: EditRecipe] = [:]
        for chunk in ids.chunked(into: 500) {
            let list = chunk.map(String.init).joined(separator: ",")
            let rows = try db.query("SELECT photo_id, recipe FROM edits WHERE photo_id IN (\(list))") { ($0.int(0), $0.blob(1)) }
            for (id, data) in rows { if let data, let r = EditRecipe.decode(data) { out[id] = r } }
        }
        return out
    }

    /// Saves (or clears, for an identity recipe) the edit recipe. Returns the new `editedAt` value.
    @discardableResult
    func saveRecipe(_ recipe: EditRecipe, for id: Int64) throws -> Date? {
        if recipe.isIdentity {
            try db.transaction { tx in
                try tx.execute("DELETE FROM edits WHERE photo_id=?", [.int(id)])
                try tx.execute("UPDATE photos SET edited_at=NULL WHERE id=?", [.int(id)])
            }
            return nil
        }
        let now = Date()
        try db.transaction { tx in
            try tx.execute("INSERT OR REPLACE INTO edits(photo_id, recipe, updated_at) VALUES (?,?,?)",
                           [.int(id), .blob(recipe.encoded()), .init(now)])
            try tx.execute("UPDATE photos SET edited_at=? WHERE id=?", [.init(now), .int(id)])
        }
        return now
    }

    // MARK: - Albums

    func albums() throws -> [Album] {
        try db.query("""
        SELECT a.id, a.name, a.created_at, (SELECT COUNT(*) FROM album_photos ap WHERE ap.album_id=a.id)
        FROM albums a ORDER BY a.name COLLATE NOCASE
        """) { Album(id: $0.int(0), name: $0.text(1), createdAt: $0.date(2), photoCount: Int($0.int(3))) }
    }

    @discardableResult
    func createAlbum(name: String) throws -> Int64 {
        try db.insert("INSERT INTO albums(name, created_at) VALUES (?,?)", [.text(name), .init(Date())])
    }

    func renameAlbum(id: Int64, name: String) throws {
        try db.execute("UPDATE albums SET name=? WHERE id=?", [.text(name), .int(id)])
    }

    func deleteAlbum(id: Int64) throws {
        try db.execute("DELETE FROM albums WHERE id=?", [.int(id)])
    }

    func photoIDs(inAlbum id: Int64) throws -> [Int64] {
        try db.query("SELECT photo_id FROM album_photos WHERE album_id=? ORDER BY added_at", [.int(id)]) { $0.int(0) }
    }

    func add(_ photoIDs: [Int64], toAlbum id: Int64) throws {
        let now = Date()
        try db.transaction { tx in
            for p in photoIDs {
                try tx.execute("INSERT OR IGNORE INTO album_photos(album_id, photo_id, added_at) VALUES (?,?,?)",
                               [.int(id), .int(p), .init(now)])
            }
        }
    }

    func remove(_ photoIDs: [Int64], fromAlbum id: Int64) throws {
        try db.transaction { tx in
            for p in photoIDs { try tx.execute("DELETE FROM album_photos WHERE album_id=? AND photo_id=?", [.int(id), .int(p)]) }
        }
    }

    // MARK: - Analysis cache

    struct AnalysisRow: Sendable {
        var photoID: Int64
        var signature: String
        var sha256: String?
        var aHash: UInt64?
        var dHash: UInt64?
        var pHash: UInt64?
        var featureRevision: Int?
        var feature: Data?
        var sharpness: Double?
        var exposureScore: Double?
        var aesthetic: Double?
        var isUtility: Bool?
    }

    func analysisRows() throws -> [Int64: AnalysisRow] {
        let rows = try db.query("""
        SELECT photo_id, signature, sha256, ahash, dhash, phash, fp_revision, feature, sharpness, exposure_score, aesthetic, utility
        FROM analysis
        """) { r in
            AnalysisRow(photoID: r.int(0), signature: r.text(1), sha256: r.textOrNil(2),
                        aHash: r.intOrNil(3).map { UInt64(bitPattern: $0) }, dHash: r.intOrNil(4).map { UInt64(bitPattern: $0) },
                        pHash: r.intOrNil(5).map { UInt64(bitPattern: $0) }, featureRevision: r.intOrNil(6).map { Int($0) },
                        feature: r.blob(7), sharpness: r.doubleOrNil(8), exposureScore: r.doubleOrNil(9),
                        aesthetic: r.doubleOrNil(10), isUtility: r.intOrNil(11).map { $0 != 0 })
        }
        return Dictionary(rows.map { ($0.photoID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func saveAnalysis(_ rows: [AnalysisRow]) throws {
        guard !rows.isEmpty else { return }
        let now = Date()
        try db.transaction { tx in
            for a in rows {
                try tx.execute("""
                INSERT OR REPLACE INTO analysis(photo_id, signature, sha256, ahash, dhash, phash, fp_revision, feature,
                    sharpness, exposure_score, aesthetic, utility, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [
                    .int(a.photoID), .text(a.signature), .init(a.sha256),
                    .init(a.aHash.map { Int64(bitPattern: $0) }), .init(a.dHash.map { Int64(bitPattern: $0) }),
                    .init(a.pHash.map { Int64(bitPattern: $0) }), .init(a.featureRevision), .init(a.feature),
                    .init(a.sharpness), .init(a.exposureScore), .init(a.aesthetic),
                    a.isUtility.map { Database.Value.init($0) } ?? .null, .init(now)
                ])
            }
        }
    }

    func clearAnalysisCache() throws { try db.execute("DELETE FROM analysis") }

    // MARK: - Trash log

    func logTrash(photoID: Int64?, originalPath: String, trashPath: String, fileSize: Int64, snapshot: Data?) throws {
        try db.insert("""
        INSERT INTO trash(photo_id, original_path, trash_path, filename, file_size, trashed_at, snapshot)
        VALUES (?,?,?,?,?,?,?)
        """, [.init(photoID), .text(originalPath), .text(trashPath), .text((originalPath as NSString).lastPathComponent),
              .int(fileSize), .init(Date()), .init(snapshot)])
    }

    func trashEntries() throws -> [TrashEntry] {
        try db.query("""
        SELECT id, original_path, trash_path, filename, file_size, trashed_at, photo_id FROM trash
        WHERE restored=0 ORDER BY trashed_at DESC
        """) {
            TrashEntry(id: $0.int(0), originalPath: $0.text(1), trashPath: $0.text(2), filename: $0.text(3),
                       fileSize: $0.int(4), trashedAt: $0.date(5), photoID: $0.intOrNil(6))
        }
    }

    func trashSnapshot(id: Int64) throws -> Data? {
        try db.query("SELECT snapshot FROM trash WHERE id=?", [.int(id)]) { $0.blob(0) }.first ?? nil
    }

    func markRestored(_ id: Int64) throws { try db.execute("UPDATE trash SET restored=1 WHERE id=?", [.int(id)]) }
    func forgetTrashEntry(_ id: Int64) throws { try db.execute("DELETE FROM trash WHERE id=?", [.int(id)]) }

    // MARK: - Export history

    func logExport(destination: String, format: String, count: Int, failed: Int, bytes: Int64, source: String) throws {
        try db.insert("INSERT INTO exports(date, destination, format, count, failed, total_bytes, source) VALUES (?,?,?,?,?,?,?)",
                      [.init(Date()), .text(destination), .text(format), .int(Int64(count)), .int(Int64(failed)), .int(bytes), .text(source)])
    }

    func exportHistory() throws -> [ExportHistoryEntry] {
        try db.query("SELECT id, date, destination, format, count, failed, total_bytes, source FROM exports ORDER BY date DESC LIMIT 500") {
            ExportHistoryEntry(id: $0.int(0), date: $0.date(1), destination: $0.text(2), format: $0.text(3),
                               count: Int($0.int(4)), failed: Int($0.int(5)), totalBytes: $0.int(6), source: $0.text(7))
        }
    }

    func clearExportHistory() throws { try db.execute("DELETE FROM exports") }

    // MARK: - Custom presets

    func customPresets() throws -> [Preset] {
        try db.query("SELECT id, name, recipe, adaptive FROM presets ORDER BY created_at") { r in
            Preset(id: r.text(0), name: r.text(1), recipe: r.blob(2).flatMap(EditRecipe.decode) ?? .identity,
                   adaptive: r.bool(3), isBuiltIn: false)
        }
    }

    func savePreset(_ p: Preset) throws {
        try db.execute("INSERT OR REPLACE INTO presets(id, name, recipe, adaptive, created_at) VALUES (?,?,?,?,?)",
                       [.text(p.id), .text(p.name), .blob(p.recipe.encoded()), .init(p.adaptive), .init(Date())])
    }

    func deletePreset(id: String) throws { try db.execute("DELETE FROM presets WHERE id=?", [.text(id)]) }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
