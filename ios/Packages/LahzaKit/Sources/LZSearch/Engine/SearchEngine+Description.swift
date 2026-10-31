import Foundation
import LZEmbedding
import LZIndex

extension SearchEngine {
    /// The share of the model's score left when a negative prompt beats the description ("soccer on a TV screen").
    static let negativeFactor: Float = 0.3
    /// The share left for a concept about people doing something when the photo shows nobody.
    static let nobodyFactor: Float = 0.6

    /// With the image model: the query's words about its photos (every visual slot, words that turned out not to be a
    /// place, people Lahza can't search yet, "selfie") become one description slot. Its vector is the concept table's
    /// when the words are a concept (with its negative prompts), the text model's otherwise; the photo tags of the
    /// concepts it names stay a precision signal (``VisualTarget``). A word that is one tagged concept keeps its chip
    /// and related tags (E24). Without a vector for the words, a tagged word works as in Milestone A.
    func describeVisual(_ parsed: ParsedQuery, slots: inout [ResolvedSlot], query: inout PreparedQuery, overrides: ResolutionOverrides,
                        reader: IndexReader, snapshot: SearchSnapshot, content: ContentSignals, embedding: EmbeddingContext) async throws {
        let parts = slots.filter { !$0.isSupported && ($0.slot.kind == .visual || $0.slot.kind == .people) }
        guard let first = parts.first?.id, let store = embedding.store,
              let (typed, span) = Description.text(ParsedQuery(text: parsed.text, slots: slots.map(\.slot)), parts: Set(parts.map(\.id))) else { return }
        // Counts and "without people" go to Vision's person counts; the rest is for the model.
        let (description, people) = PeopleWords.parse(typed)
        query.plan.people = people
        let vocabulary = VisualVocabulary.english
        let concepts = content.contains(.tags) && snapshot.hasVisualPass && !description.isEmpty
            ? Description.concepts(in: description, vocabulary: vocabulary) : []
        let whole = vocabulary.concept(for: description)
        let single = concepts.count == 1 && whole?.name == concepts[0].name ? concepts[0] : nil

        // The vector: the table's for its concepts, the text model's for anything else.
        var vector: [Float]?
        var negatives: [[Float]] = []
        if let table = embedding.table, let position = table.concept(for: single?.name ?? description) ?? whole.flatMap({ table.concept(for: $0.name) })
            ?? (whole?.labels.count == 1 ? whole.flatMap { table.label($0.labels[0]) } : nil) {
            vector = table.vector(position)
            negatives = table.index.entries[position].negatives.map(table.vector)
        } else if let encoder = embedding.encoder, encoder.model != nil {
            let templates = embedding.table?.index.templates ?? ["{}"]
            vector = try await encoder.embed(templates.map { $0.replacingOccurrences(of: "{}", with: description.lowercased()) })
        }
        if description.isEmpty, let people {
            // Only a count ("without people"): no words for the model.
            let slot = QuerySlot(id: first, value: .visual(typed), span: span)
            let match = VisualMatch(concept: typed, tags: [], related: [], described: true, people: people.words)
            replace(parts, with: ResolvedSlot(slot: slot, resolution: .visual(match), chip: "\(typed) · photo check", systemImage: "person.2"),
                    slots: &slots, query: &query, parsed: parsed)
            return
        }
        guard let vector,
              let column = try await Self.column(vector, negatives: negatives, needsPerson: concepts.contains(where: \.needsPerson), store: store,
                                                 snapshot: snapshot, calibrated: content.contains(.calibration), model: embedding.model) else {
            fallBackToTags(parts, slots: &slots, query: &query, overrides: overrides, snapshot: snapshot, content: content)
            if !query.plan.visual.isEmpty {
                let names = Array(Set(query.plan.visual.flatMap { $0.tags.flatMap { $0.concept.labels + $0.related } }))
                let postings = try await reader.labelPostings(names)
                query.plan.visual = query.plan.visual.map { target in
                    VisualTarget(slot: target.slot, concept: target.concept, related: target.related, postings: postings, snapshot: snapshot)
                }
            }
            return
        }

        let withoutRelated = overrides.withoutRelatedTags.contains(first)
        let related = single.map { withoutRelated ? [] : $0.related } ?? []
        let names = Array(Set(concepts.flatMap(\.labels) + related))
        let postings = names.isEmpty ? [:] : try await reader.labelPostings(names)
        let tags = concepts.map { TagMatch(concept: $0, related: $0.name == single?.name ? related : [], postings: postings, snapshot: snapshot) }
        let kind: VisualConcept.Kind = concepts.contains { $0.kind == .document } ? .document : concepts.contains { $0.kind == .occasion } ? .occasion : .thing
        let concept = single ?? VisualConcept(name: description, labels: [], kind: kind, needsPerson: concepts.contains(where: \.needsPerson))
        query.plan.visual.append(VisualTarget(slot: first, concept: concept, tags: tags, embedding: column))
        query.visualSlots.append(first)

        // One chip for the description, in the place of its first part; the chips edit the parse with the parts as one.
        let match = VisualMatch(concept: concept.name, tags: Self.readable(concepts.flatMap(\.labels)), related: Self.readable(single?.related ?? []),
                                relatedRemoved: withoutRelated, described: single == nil, people: people?.words)
        let slot = QuerySlot(id: first, value: .visual(typed), span: span)
        let chip = ResolvedSlot(slot: slot, resolution: .visual(match), chip: people == nil ? single?.chip ?? "\(description) · AI search" : "\(typed) · AI search",
                                systemImage: single == nil || people != nil ? "sparkles" : "tag")
        replace(parts, with: chip, slots: &slots, query: &query, parsed: parsed)
    }

    /// One chip in the place of a description's parts; the chips edit the parse with the parts as one slot.
    private func replace(_ parts: [ResolvedSlot], with chip: ResolvedSlot, slots: inout [ResolvedSlot], query: inout PreparedQuery, parsed: ParsedQuery) {
        let others = Set(parts.map(\.id)).subtracting([chip.id])
        slots = slots.compactMap { $0.id == chip.id ? chip : others.contains($0.id) ? nil : $0 }
        query.parsed = ParsedQuery(text: parsed.text, slots: parsed.slots.compactMap { $0.id == chip.id ? chip.slot : others.contains($0.id) ? nil : $0 },
                                   parser: parsed.parser, isEdited: parsed.isEdited)
    }

    /// No vector for the words (the table hasn't them and there is no text model): each tagged word is its own slot, as
    /// in Milestone A; the rest stay words Lahza can't search yet.
    private func fallBackToTags(_ parts: [ResolvedSlot], slots: inout [ResolvedSlot], query: inout PreparedQuery, overrides: ResolutionOverrides,
                                snapshot: SearchSnapshot, content: ContentSignals) {
        guard snapshot.hasVisualPass, content.contains(.tags) else { return }
        for part in parts {
            guard case .visual(let words) = part.slot.value, let concept = VisualVocabulary.english.concept(for: words),
                  let index = slots.firstIndex(where: { $0.id == part.id }) else { continue }
            let withoutRelated = overrides.withoutRelatedTags.contains(part.id)
            query.plan.visual.append(VisualTarget(slot: part.id, concept: concept, related: withoutRelated ? [] : concept.related, postings: [:],
                                                  snapshot: snapshot))
            query.visualSlots.append(part.id)
            let match = VisualMatch(concept: concept.name, tags: Self.readable(concept.labels), related: Self.readable(concept.related),
                                    relatedRemoved: withoutRelated)
            slots[index] = ResolvedSlot(slot: part.slot, resolution: .visual(match), chip: concept.chip, systemImage: "tag")
        }
    }

    /// Every photo's model score for a description: s_emb from its z-score against the library's reference sample, less
    /// how far the confident bar sits above 3 for a library this size (``EmbeddingColumn/confidentZ(photos:)``), or
    /// SigLIP's own probability without `calibrated`; times ``negativeFactor`` when a negative prompt is closer, times
    /// ``nobodyFactor`` for a concept about people when the photo was checked and shows nobody. Nil while too few photos
    /// have a vector to judge.
    static func column(_ vector: [Float], negatives: [[Float]], needsPerson: Bool, store: VectorStore, snapshot: SearchSnapshot, calibrated: Bool,
                       model: EmbeddingModel?) async throws -> EmbeddingColumn? {
        let scores = try await store.scores(for: vector)
        let reference = ReferenceSample.pick(snapshot.id)
        var sample: [Float] = [], all: [Float] = []
        for (id, cosine) in zip(scores.assetIDs, scores.scores) where snapshot.indexByID[id] != nil {
            all.append(cosine)
            if reference.contains(id) { sample.append(cosine) }
        }
        guard let calibration = Calibration(sample: sample.count >= Calibration.minimumSample ? sample : all) else { return nil }
        var closest: [Int64: Float] = [:]
        for negative in negatives {
            let found = try await store.scores(for: negative)
            for (id, cosine) in zip(found.assetIDs, found.scores) { closest[id] = max(closest[id] ?? -1, cosine) }
        }
        var score = [Float](repeating: .nan, count: snapshot.count), z = score
        var embedded = 0, confident = false
        let bar = EmbeddingColumn.confidentZ(photos: all.count), shift = bar - 3
        for (id, cosine) in zip(scores.assetIDs, scores.scores) {
            guard let index = snapshot.indexByID[id].map(Int.init) else { continue }
            embedded += 1
            let zScore = calibration.z(cosine)
            var value = calibrated ? Float(Calibration.score(z: zScore - shift)) : model?.probability(cosine: cosine) ?? 0
            if let negative = closest[id], negative > cosine { value *= negativeFactor }
            if needsPerson, snapshot.isChecked(index), snapshot.humans[index] == 0, snapshot.faces[index] == 0 { value *= nobodyFactor }
            score[index] = value
            z[index] = zScore
            if zScore >= bar { confident = true }
        }
        return EmbeddingColumn(score: score, z: z, embedded: embedded, bar: bar, confident: confident)
    }
}
