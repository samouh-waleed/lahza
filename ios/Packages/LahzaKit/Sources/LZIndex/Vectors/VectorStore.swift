import Accelerate
import Darwin
import Foundation
import LZCore
internal import GRDB

/// One embedding per asset, in `Index/vectors.lzvf` next to the database, so it shares its data protection, its
/// backup exclusion and Delete index. The file is a 64-byte header, then fixed-size rows: an asset id (0 for a free
/// row) and the unit vector in 16-bit floats (1.5 KB at 768 dimensions).
///
/// The header names the model and carries the index's ``MetaKey/vectorIdentity``. Opening discards a file made by
/// another model, size or identity, so a new model re-embeds the library and vectors never meet the ids of a rebuilt
/// index. Search maps the file and scores every row in blocks: 16-bit to 32-bit with vImage, then one
/// matrix-vector product with vDSP.
///
/// Hold one store per index. Opening the file again, or finding it no longer current, retires the earlier store.
/// A retired store reads and writes only its own file descriptor: it never reads someone else's file, and its
/// writes are lost.
public actor VectorStore {
    public static let fileName = "vectors.lzvf"
    static let magic = Data("LZVF".utf8)
    static let formatVersion: UInt16 = 1
    /// Row values are IEEE 16-bit floats.
    static let float16: UInt16 = 1
    static let headerSize = 64
    static let modelIDLength = 32
    /// Rows converted and scored at a time (3 MB of 32-bit floats at 768 dimensions).
    static let block = 1024

    /// How ``open(_:modelID:dimension:)`` found the file.
    public enum Opening: Sendable, Hashable {
        /// Its vectors are this model's, for these asset ids.
        case existing
        /// There was none.
        case created
        /// It was for another model, dimension or index, or not a vector file: removed and started again.
        case discarded(reason: String)
    }

    /// Where each asset's row is: what the file says, never ahead of it.
    struct Table: Sendable {
        var rows = 0
        var slots: [Int64: Int] = [:]
        var freeRows: [Int] = []
    }

    public nonisolated let modelID: String
    public nonisolated let dimension: Int
    public nonisolated let opening: Opening
    nonisolated let url: URL
    private let identity: UUID
    private let database: IndexDatabase
    /// An in-memory index keeps its vectors in a temporary file, removed with the store.
    private let isTemporary: Bool
    private let handle: FileHandle
    private var table: Table
    /// The file mapped for search, through ``handle``; dropped by every write.
    private var mapped: Data?
    private static let log = Log("vectors")

    private nonisolated var stride: Int { 8 + dimension * 2 }

    private init(url: URL, isTemporary: Bool, identity: UUID, database: IndexDatabase, modelID: String, dimension: Int,
                 opening: Opening, handle: FileHandle, table: Table) {
        self.url = url
        self.isTemporary = isTemporary
        self.identity = identity
        self.database = database
        self.modelID = modelID
        self.dimension = dimension
        self.opening = opening
        self.handle = handle
        self.table = table
    }

    deinit {
        try? handle.close()
        if isTemporary { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Opening

    /// Opens the index's vector file for `modelID`, creating it, or discarding one that doesn't match. A file that
    /// can't be read right now (out of descriptors, an I/O error) throws and is left for a later try.
    public static func open(_ database: IndexDatabase, modelID: String, dimension: Int) async throws -> VectorStore {
        precondition(!modelID.isEmpty && modelID.utf8.count <= modelIDLength, "model id must be 1–\(modelIDLength) bytes")
        precondition(dimension > 0)
        let identity = try await database.vectorIdentity()
        let url: URL, isTemporary: Bool
        if let folder = try IndexDatabase.folder(for: database.location) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent(fileName)
            isTemporary = false
        } else {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("lz-vectors-\(UUID().uuidString).lzvf")
            isTemporary = true
        }
        let expected = header(identity: identity, modelID: modelID, dimension: dimension)
        var opening = Opening.created
        if FileManager.default.fileExists(atPath: url.path) {
            if let reason = try mismatch(at: url, expected: expected) {
                try FileManager.default.removeItem(at: url)
                opening = .discarded(reason: reason)
                log.notice("Vector file discarded: \(reason)", privacy: .public)
            } else {
                opening = .existing
            }
        }
        if opening != .existing {
            guard FileManager.default.createFile(atPath: url.path, contents: expected) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forUpdating: url)
        let table = try scan(handle, stride: 8 + dimension * 2)
        return VectorStore(url: url, isTemporary: isTemporary, identity: identity, database: database, modelID: modelID,
                           dimension: dimension, opening: opening, handle: handle, table: table)
    }

    static func header(identity: UUID, modelID: String, dimension: Int) -> Data {
        var data = magic
        withUnsafeBytes(of: formatVersion.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: float16.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(dimension).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0, 0, 0, 0])
        withUnsafeBytes(of: identity.uuid) { data.append(contentsOf: $0) }
        var model = Data(modelID.utf8)
        model.append(Data(count: modelIDLength - model.count))
        data.append(model)
        return data
    }

    /// Why the file at `url` can't be used with `expected`'s model, dimension and identity, or nil. Throws when the
    /// file can't be read, which says nothing about its contents.
    private static func mismatch(at url: URL, expected: Data) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let found = try handle.read(upToCount: headerSize) ?? Data()
        guard found.count == headerSize else { return "no header" }
        if found.prefix(8) != expected.prefix(8) { return found.prefix(4) == magic ? "format" : "not a vector file" }
        if found[8..<12] != expected[8..<12] { return "dimension" }
        if found[32..<64] != expected[32..<64] { return "model" }
        if found[16..<32] != expected[16..<32] { return "index rebuilt" }
        return nil
    }

    /// The rows the file holds, after dropping a partial last row (a write cut short).
    private static func scan(_ handle: FileHandle, stride: Int) throws -> Table {
        let size = Int(try handle.seekToEnd())
        let rows = max(0, (size - headerSize) / stride)
        if headerSize + rows * stride != size { try handle.truncate(atOffset: UInt64(headerSize + rows * stride)) }
        var table = Table(rows: rows)
        guard rows > 0 else { return table }
        try map(handle).withUnsafeBytes { raw in
            for row in 0..<min(rows, (raw.count - headerSize) / stride) {
                let id = raw.loadUnaligned(fromByteOffset: headerSize + row * stride, as: Int64.self)
                if id == 0 { table.freeRows.append(row) } else { table.slots[id] = row }
            }
        }
        return table
    }

    /// The whole file behind `handle`, mapped read-only through that descriptor (so it is always this store's file).
    private static func map(_ handle: FileHandle) throws -> Data {
        let descriptor = handle.fileDescriptor
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let size = Int(info.st_size)
        guard size > 0 else { return Data() }
        let address = mmap(nil, size, PROT_READ, MAP_SHARED, descriptor, 0)
        guard let address, address != UnsafeMutableRawPointer(bitPattern: -1) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Data(bytesNoCopy: address, count: size, deallocator: .custom { pointer, count in munmap(pointer, count) })
    }

    // MARK: Reading

    /// Assets with a vector.
    public var count: Int { table.slots.count }

    public func contains(_ assetID: Int64) -> Bool { table.slots[assetID] != nil }

    /// Whether the index still has this file's asset ids (false after Settings › Rebuild). If not, retire this store
    /// and open the file again.
    public func isCurrent() async throws -> Bool {
        try await database.isVectorIdentity(identity)
    }

    /// The stored vector (16-bit, so within about 0.001 of what was written), or nil.
    public func vector(for assetID: Int64) throws -> [Float]? {
        guard let row = table.slots[assetID] else { return nil }
        let data = try mapping()
        guard Self.headerSize + (row + 1) * stride <= data.count else { return nil }
        var vector = [Float](repeating: 0, count: dimension)
        data.withUnsafeBytes { raw in
            vector.withUnsafeMutableBufferPointer { floats in
                Self.widen(raw.baseAddress! + Self.headerSize + row * stride + 8, rows: 1, rowBytes: stride, dimension: dimension,
                           into: floats.baseAddress!)
            }
        }
        return vector
    }

    /// Every stored asset's cosine with `query` (normalised first), in file order.
    public func scores(for query: [Float]) throws -> VectorScores {
        precondition(query.count == dimension, "query has \(query.count) dimensions, not \(dimension)")
        var result = VectorScores(assetIDs: [], scores: [])
        guard table.rows > 0 else { return result }
        result.assetIDs.reserveCapacity(table.slots.count)
        result.scores.reserveCapacity(table.slots.count)
        let unit = Self.normalized(query)
        let data = try mapping()
        let dimension = dimension, stride = stride
        // Never past what is mapped, whatever the table says.
        let rows = min(table.rows, max(0, (data.count - Self.headerSize) / stride))
        var floats = [Float](repeating: 0, count: Self.block * dimension)
        var products = [Float](repeating: 0, count: Self.block)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress! + Self.headerSize
            for start in Swift.stride(from: 0, to: rows, by: Self.block) {
                let count = min(Self.block, rows - start)
                floats.withUnsafeMutableBufferPointer { block in
                    Self.widen(base + start * stride + 8, rows: count, rowBytes: stride, dimension: dimension, into: block.baseAddress!)
                    products.withUnsafeMutableBufferPointer { out in
                        vDSP_mmul(block.baseAddress!, 1, unit, 1, out.baseAddress!, 1, vDSP_Length(count), 1, vDSP_Length(dimension))
                    }
                }
                for row in 0..<count {
                    let id = raw.loadUnaligned(fromByteOffset: Self.headerSize + (start + row) * stride, as: Int64.self)
                    if id != 0 {
                        result.assetIDs.append(id)
                        result.scores.append(products[row])
                    }
                }
            }
        }
        return result
    }

    // MARK: Writing

    /// Stores each asset's vector (normalised first), replacing any it had; freed rows are reused first. The rows are
    /// planned on a copy of the table, which is kept only once every write has landed. After a failed write the table
    /// is read again from the file.
    public func upsert(_ entries: [VectorEntry]) throws {
        guard !entries.isEmpty else { return }
        mapped = nil
        var planned = table
        var writes: [(row: Int, bytes: Data)] = []
        writes.reserveCapacity(entries.count)
        for entry in entries {
            precondition(entry.assetID > 0, "asset ids start at 1")
            precondition(entry.vector.count == dimension, "vector has \(entry.vector.count) dimensions, not \(dimension)")
            let row: Int
            if let existing = planned.slots[entry.assetID] {
                row = existing
            } else if let free = planned.freeRows.popLast() {
                row = free
            } else {
                row = planned.rows
                planned.rows += 1
            }
            planned.slots[entry.assetID] = row
            var bytes = Data(capacity: stride)
            withUnsafeBytes(of: entry.assetID.littleEndian) { bytes.append(contentsOf: $0) }
            bytes.append(Self.narrow(Self.normalized(entry.vector)))
            writes.append((row, bytes))
        }
        // Consecutive rows (a batch of new assets) go out in one write.
        writes.sort { $0.row < $1.row }
        do {
            var index = 0
            while index < writes.count {
                var run = writes[index].bytes
                var next = index + 1
                while next < writes.count, writes[next].row == writes[next - 1].row + 1 {
                    run.append(writes[next].bytes)
                    next += 1
                }
                try handle.seek(toOffset: UInt64(Self.headerSize + writes[index].row * stride))
                try handle.write(contentsOf: run)
                index = next
            }
        } catch {
            if let reread = try? Self.scan(handle, stride: stride) { table = reread }
            throw error
        }
        table = planned
    }

    /// Forgets the assets' vectors; their rows are reused by later upserts. Each is forgotten once its row is freed
    /// in the file.
    public func remove(_ assetIDs: some Sequence<Int64>) throws {
        mapped = nil
        let empty = Data(count: 8)
        for id in assetIDs {
            guard let row = table.slots[id] else { continue }
            try handle.seek(toOffset: UInt64(Self.headerSize + row * stride))
            try handle.write(contentsOf: empty)
            table.slots.removeValue(forKey: id)
            table.freeRows.append(row)
        }
    }

    // MARK: Support

    private func mapping() throws -> Data {
        if let mapped { return mapped }
        let data = try Self.map(handle)
        mapped = data
        return data
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let length = sqrt(vDSP.sumOfSquares(vector))
        return length > 0 ? vDSP.divide(vector, length) : vector
    }

    /// 32-bit floats to 16-bit (round to nearest).
    static func narrow(_ vector: [Float]) -> Data {
        var data = Data(count: vector.count * 2)
        vector.withUnsafeBufferPointer { source in
            data.withUnsafeMutableBytes { target in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1,
                                         width: vImagePixelCount(vector.count), rowBytes: vector.count * 4)
                var to = vImage_Buffer(data: target.baseAddress!, height: 1, width: vImagePixelCount(vector.count), rowBytes: vector.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        return data
    }

    /// `rows` 16-bit vectors, `rowBytes` apart, to packed 32-bit floats.
    static func widen(_ source: UnsafeRawPointer, rows: Int, rowBytes: Int, dimension: Int, into target: UnsafeMutablePointer<Float>) {
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(rows),
                                 width: vImagePixelCount(dimension), rowBytes: rowBytes)
        var to = vImage_Buffer(data: target, height: vImagePixelCount(rows), width: vImagePixelCount(dimension), rowBytes: dimension * 4)
        _ = vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
    }
}

/// An asset's embedding to store.
public struct VectorEntry: Sendable {
    public var assetID: Int64
    public var vector: [Float]

    public init(assetID: Int64, vector: [Float]) {
        self.assetID = assetID
        self.vector = vector
    }
}

/// Cosines with a query for every stored asset, in file order (parallel arrays, ready for per-slot scoring).
public struct VectorScores: Sendable {
    public var assetIDs: [Int64]
    public var scores: [Float]

    /// The `limit` highest, best first (ties by asset id).
    public func top(_ limit: Int) -> [(assetID: Int64, score: Float)] {
        zip(assetIDs, scores).sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map { ($0.0, $0.1) }
    }
}

extension IndexDatabase {
    /// ``MetaKey/vectorIdentity``, created when absent.
    func vectorIdentity() async throws -> UUID {
        try await write { db in
            if let text = try Meta.string(db, .vectorIdentity), let identity = UUID(uuidString: text) { return identity }
            let identity = UUID()
            try Meta.set(db, .vectorIdentity, identity.uuidString)
            return identity
        }
    }

    func isVectorIdentity(_ identity: UUID) async throws -> Bool {
        try await read { db in try Meta.string(db, .vectorIdentity) == identity.uuidString }
    }
}
