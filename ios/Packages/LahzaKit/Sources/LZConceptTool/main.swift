import Foundation
import LZEmbedding
import LZSearch

/// `lz-concepts`: builds what the text side of content search reads (macOS, never in the app).
///
///     lz-concepts vocab --tokenizer <tokenizer.json> --out <siglip2-vocab.lzvb>
///     lz-concepts table --model <model folder> --concepts <Concepts.txt> --out <Concepts.lzcv>
///
/// `vocab` turns Hugging Face's tokenizer.json into the compact vocabulary file ``GemmaTokenizer`` reads (`make tokenizer`).
/// `table` embeds every concept, Vision tag and negative prompt with the same tokenizer and text tower the iPhone uses
/// (`make concepts`): the word map's concepts and Vision's tags come from search's bundled lists, the rest from
/// Concepts.txt.
@main
struct ConceptTool {
    static let templates = ["a photo of {}.", "a picture of {}.", "{}.", "a close-up photo of {}.", "an image showing {}."]

    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { usage() }
        arguments.removeFirst()
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let started = Date()
        switch command {
        case "vocab":
            guard let input = value("--tokenizer"), let output = value("--out") else { usage() }
            let data = try TokenizerVocabulary.build(fromTokenizerJSON: Data(contentsOf: URL(fileURLWithPath: input)))
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            let vocabulary = try TokenizerVocabulary(data: data)
            print("Wrote \(output): \(data.count / 1_024) KB, \(vocabulary.mergeCount) merges, in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        case "table":
            guard let folder = value("--model"), let concepts = value("--concepts"), let output = value("--out") else { usage() }
            let encoder = ModelFolderTextEncoder(folder: URL(fileURLWithPath: folder, isDirectory: true))
            guard let model = encoder.model else { throw EmbeddingError.missingModel("\(folder): model.json, the text tower or the vocabulary") }
            let index = try plan(lines: String(contentsOfFile: concepts, encoding: .utf8), model: model)
            var vectors: [[Float]] = []
            vectors.reserveCapacity(index.entries.count)
            for (position, entry) in index.entries.enumerated() {
                vectors.append(try await encoder.embed(templates.map { $0.replacingOccurrences(of: "{}", with: entry.phrase) }))
                if position % 250 == 0 { print("\(position) of \(index.entries.count)") }
            }
            let data = try ConceptTable.encode(index, vectors: vectors)
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            let kinds = Dictionary(grouping: index.entries, by: \.kind).mapValues(\.count)
            print("Wrote \(output): \(data.count / 1_024) KB, \(kinds[.concept] ?? 0) concepts, \(kinds[.label] ?? 0) tags, "
                  + "\(kinds[.negative] ?? 0) negative prompts, in \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
        default:
            usage()
        }
    }

    /// The table's entries: the word map's concepts (with Concepts.txt's phrase and negatives when it has a line for
    /// them), Concepts.txt's own concepts, Vision's tags, then the negative prompts they name.
    static func plan(lines text: String, model: EmbeddingModel) throws -> ConceptTable.Index {
        var phrases: [String: String] = [:], negatives: [String: [String]] = [:], order: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let name = fields[0].lowercased()
            guard !name.isEmpty, phrases[name] == nil else { throw CocoaError(.formatting, userInfo: [NSDebugDescriptionErrorKey: "repeated or empty: \(line)"]) }
            phrases[name] = fields.count > 1 && !fields[1].isEmpty ? fields[1] : name
            negatives[name] = fields.count > 2 ? fields[2].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
            order.append(name)
        }
        let vocabulary = VisualVocabulary.english
        var entries: [ConceptTable.Entry] = [], names = Set<String>()
        func addConcept(_ name: String) {
            guard names.insert(name).inserted else { return }
            entries.append(ConceptTable.Entry(name: name, kind: .concept, phrase: phrases[name] ?? name))
        }
        for concept in vocabulary.curatedConcepts { addConcept(concept.name) }
        for name in order { addConcept(name) }
        for label in vocabulary.labels {
            entries.append(ConceptTable.Entry(name: label, kind: .label, phrase: VisualVocabulary.readable(label)))
        }
        var negativeIndex: [String: Int] = [:]
        for position in entries.indices where entries[position].kind == .concept {
            for negative in negatives[entries[position].name] ?? [] {
                if negativeIndex[negative] == nil {
                    negativeIndex[negative] = entries.count
                    entries.append(ConceptTable.Entry(name: negative, kind: .negative, phrase: negative))
                }
                entries[position].negatives.append(negativeIndex[negative]!)
            }
        }
        return ConceptTable.Index(model: model.id, revision: model.revision, dimension: model.dimension, templates: templates, entries: entries)
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data("""
            usage: lz-concepts vocab --tokenizer <tokenizer.json> --out <file.lzvb>
                   lz-concepts table --model <model folder> --concepts <Concepts.txt> --out <Concepts.lzcv>

            """.utf8))
        exit(2)
    }
}
