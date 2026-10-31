import Foundation
internal import GRDB

/// A photo a tag was given to: its row id, the tag's confidence (comparable only within the tag) and flags.
public struct LabelPosting: Sendable, Hashable {
    public var assetID: Int64
    public var confidence: Float
    public var flags: VisualLabelFlags
}

/// One photo as the Vision pass saw it (the label lab).
public struct VisualSample: Sendable, Hashable, Identifiable {
    public var assetID: Int64
    public var localID: String
    public var createdUTC: Int64?
    public var status: VisualStatus
    public var faces: Int
    public var humans: Int
    public var isUtility: Bool
    public var aesthetic: Double?
    /// Most confident first.
    public var labels: [VisualLabel]

    public var id: Int64 { assetID }
}

/// The Vision pass in numbers (the label lab).
public struct VisualStats: Sendable, Hashable {
    public var assets: Int
    public var checked: Int
    public var pendingCloud: Int
    public var failed: Int
    /// Tag rows over checked photos.
    public var labelRows: Int
    /// Distinct tags given at least once.
    public var labelsUsed: Int
    /// The iPhone's tag list, as the pass recorded it.
    public var supported: [String]
}

extension IndexReader {
    /// The photos given each of `names` (tags no photo has are left out).
    public func labelPostings(_ names: [String]) async throws -> [String: [LabelPosting]] {
        guard !names.isEmpty else { return [:] }
        return try await database.read { db in
            let marks = Array(repeating: "?", count: names.count).joined(separator: ", ")
            var postings: [String: [LabelPosting]] = [:]
            let rows = try Row.fetchCursor(db, sql: """
                SELECT l.name, a.asset_id, a.confidence, a.flags FROM asset_label a JOIN visual_label l ON l.id = a.label_id WHERE l.name IN (\(marks))
                """, arguments: StatementArguments(names))
            while let row = try rows.next() {
                postings[row[0], default: []].append(LabelPosting(assetID: row[1], confidence: Float(row[2] as Double),
                                                                   flags: VisualLabelFlags(rawValue: UInt8(clamping: row[3] as Int))))
            }
            return postings
        }
    }

    /// The most recently checked photos (or those only in iCloud, or that failed) with their tags, newest first.
    public func visualSamples(limit: Int, status: VisualStatus = .done) async throws -> [VisualSample] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.local_id, a.created_utc, v.status, v.faces, v.humans, v.is_utility, v.aesthetic
                FROM asset_visual v JOIN asset a ON a.id = v.asset_id WHERE v.status = ? ORDER BY a.created_utc DESC LIMIT ?
                """, arguments: [status.rawValue, max(0, limit)])
            return try rows.map { row in
                let id: Int64 = row[0]
                let labels = try Row.fetchAll(db, sql: """
                    SELECT l.name, a.confidence, a.flags FROM asset_label a JOIN visual_label l ON l.id = a.label_id WHERE a.asset_id = ?
                    ORDER BY a.flags DESC, a.confidence DESC
                    """, arguments: [id]).map { label in
                    VisualLabel(name: label[0], confidence: Float(label[1] as Double), flags: VisualLabelFlags(rawValue: UInt8(clamping: label[2] as Int)))
                }
                return VisualSample(assetID: id, localID: row[1], createdUTC: row[2], status: VisualStatus(rawValue: row[3]) ?? .pending,
                                    faces: row[4] ?? 0, humans: row[5] ?? 0, isUtility: row[6] ?? false, aesthetic: row[7], labels: labels)
            }
        }
    }

    public func visualStats() async throws -> VisualStats {
        try await database.read { db in
            func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
            return VisualStats(assets: try count("SELECT COUNT(*) FROM asset"),
                               checked: try count("SELECT COUNT(*) FROM asset_visual WHERE status = 1"),
                               pendingCloud: try count("SELECT COUNT(*) FROM asset_visual WHERE status = 2"),
                               failed: try count("SELECT COUNT(*) FROM asset_visual WHERE status = 3"),
                               labelRows: try count("SELECT COUNT(*) FROM asset_label"),
                               labelsUsed: try count("SELECT COUNT(DISTINCT label_id) FROM asset_label"),
                               supported: try String.fetchAll(db, sql: "SELECT name FROM visual_label ORDER BY name"))
        }
    }
}
