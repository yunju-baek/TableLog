import Foundation

/// Personal classifier parameters learned from explicitly labelled TitaNet embeddings.
/// The bundled TitaNet feature extractor stays fixed; each training pass refits this classifier.
enum VoiceLearningState: String, Codable {
    case validationPending, validated, retainedPrevious
}

struct VoiceLearningValidation: Codable, Equatable {
    var positiveRecall: Double?
    var falseAcceptRate: Double?
    var baselinePositiveRecall: Double?
    var baselineFalseAcceptRate: Double?
    var heldOutPositiveCount: Int
    var heldOutNegativeCount: Int
    var sourceFoldCount: Int
    var passed: Bool?
    var note: String
}

struct VoiceLearnedModel: Codable, Equatable {
    var algorithm = "source-balanced-spherical-prototypes-v1"
    var dimension = 192
    /// Revision of the training attempt. parameterRevision changes only when scoring parameters change.
    var revision: Int
    var parameterRevision: Int
    var trainedAt: Date
    /// Current valid labelled corpus, including evidence kept for replay after a rejected candidate.
    var sampleCount: Int
    var sourceCount: Int
    var effectiveSampleCount: Int
    /// Exact corpus used by the active parameters, for leakage-free baseline refitting.
    var trainingSampleIDs: [UUID]
    var negativeSampleIDs: [UUID]
    var prototypes: [[Float]]
    var prototypeSupport: [Int]
    var prototypeThresholds: [Float]
    var centroid: [Float]
    var state: VoiceLearningState
    var validation: VoiceLearningValidation
    var supportsAutomaticMapping: Bool
    var automaticEligible: Bool {
        supportsAutomaticMapping && state == .validated && validation.passed == true &&
        (validation.positiveRecall ?? -1) >= 0.60 && (validation.falseAcceptRate ?? 1) <= 0.10 &&
        VoiceLearningTrainer.valid(self)
    }
    /// A retained initial centroid is reproduced as one prototype in future validation folds.
    var prototypeLimit: Int
}

enum VoiceLearningTrainer {
    static let dimension = 192
    static let maximumPrototypes = 8
    static let decisionThreshold: Float = 0.65
    private static let impostorMargin: Float = 0.08
    private static let sourceSimilarity: Float = 0.998

    private struct Example {
        let id: UUID
        let source: String
        let vector: [Float]
        let seconds: Double
    }
    private struct Point {
        var vector: [Float]
        var weight: Double
        var count: Int
    }
    private struct Parameters {
        var centers: [[Float]]
        var support: [Int]
        var thresholds: [Float]
        var centroid: [Float]
        var effectiveCount: Int
    }

    /// A source is a recording/session, never an individual chunk from that same recording.
    static func sourceKey(_ sample: VoiceSample) -> String {
        let source = sample.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = source.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, ["meeting", "recording", "file", "enrollment", "confirmed"].contains(String(parts[0])), !parts[1].isEmpty {
            return parts.prefix(2).joined(separator: ":")
        }
        // Legacy chunk labels carry no recording identifier. A UTC day is intentionally conservative.
        if source.isEmpty || source == "user_confirmed" {
            let day = String(format: "%.0f", floor(sample.created.timeIntervalSince1970 / 86400))
            return "legacy-day:\(day)"
        }
        return source
    }

    /// Refits bounded spherical prototypes from the complete retained labelled corpus.
    /// Source-balanced weights and near-duplicate consolidation prevent a long meeting dominating.
    static func train(profileSamples: [VoiceSample], otherProfiles: [VoiceProfile],
                      previous: VoiceLearnedModel? = nil, now: Date = Date()) -> VoiceLearnedModel? {
        let positives = examples(profileSamples)
        guard !positives.isEmpty else { return nil }
        let allNegativeGroups = otherProfiles.sorted { $0.id.uuidString < $1.id.uuidString }
            .map { examples($0.samples) }.filter { !$0.isEmpty }
        // Preserve the complete positive replay corpus while bounding impostor work per identity.
        let negativeGroups = allNegativeGroups.map { boundedNegatives($0, limit: 48) }
        let negatives = negativeGroups.flatMap { $0 }
        let allNegatives = allNegativeGroups.flatMap { $0 }
        let candidate = fit(positives, negatives: negatives, limit: maximumPrototypes)
        guard !candidate.centers.isEmpty else { return nil }
        let previous = previous.flatMap { valid($0) ? $0 : nil }
        let positiveIDs = Set(positives.map(\.id)), negativeIDs = Set(allNegatives.map(\.id))
        let oldPositiveIDs = Set(previous?.trainingSampleIDs ?? [])
        let oldNegativeIDs = Set(previous?.negativeSampleIDs ?? [])
        let previousCorpusAvailable = previous != nil && oldPositiveIDs.isSubset(of: positiveIDs) && oldNegativeIDs.isSubset(of: negativeIDs)
        let baselinePositives = previous == nil ? positives : positives.filter { oldPositiveIDs.contains($0.id) }
        let baselineNegatives = previous == nil ? [] : allNegatives.filter { oldNegativeIDs.contains($0.id) }
        let validation = evaluate(positives: positives, negativesByPerson: negativeGroups,
                                  baselinePositives: baselinePositives, baselineNegatives: baselineNegatives,
                                  baselineLimit: previous?.prototypeLimit ?? 1)
        var parameters = candidate
        var acceptedPositives = positives
        var acceptedNegatives = negatives
        var limit = maximumPrototypes
        var state: VoiceLearningState = validation.passed == true ? .validated : .validationPending
        var report = validation
        if validation.passed == false {
            if let previous, previousCorpusAvailable {
                parameters = Parameters(centers: previous.prototypes, support: previous.prototypeSupport,
                                        thresholds: previous.prototypeThresholds, centroid: previous.centroid,
                                        effectiveCount: candidate.effectiveCount)
                acceptedPositives = positives.filter { oldPositiveIDs.contains($0.id) }
                acceptedNegatives = allNegatives.filter { oldNegativeIDs.contains($0.id) }
                limit = previous.prototypeLimit
                state = .retainedPrevious
                report.note += " 기존 판정 매개변수를 유지하고 추가 자료를 다음 학습에 보관했습니다."
            } else {
                // Explicit deletion/label correction takes precedence over restoring obsolete parameters.
                // Rebuild the comparison centroid from the permitted corpus; keep automatic mapping gated.
                parameters = fit(positives, negatives: [], limit: 1)
                acceptedNegatives = []
                limit = 1
                report.note += " 현재 허용된 자료의 비교 기준 벡터를 유지했습니다. 추가 출처 확인 후 다시 학습합니다."
            }
        }
        let sameParameters = previous.map {
            $0.prototypes == parameters.centers && $0.prototypeThresholds == parameters.thresholds && $0.centroid == parameters.centroid
        } ?? false
        let parameterRevision = sameParameters ? (previous?.parameterRevision ?? 1) : (previous?.parameterRevision ?? 0) + 1
        return VoiceLearnedModel(revision: (previous?.revision ?? 0) + 1,
                                 parameterRevision: parameterRevision, trainedAt: now,
                                 sampleCount: positives.count, sourceCount: Set(positives.map(\.source)).count,
                                 effectiveSampleCount: candidate.effectiveCount,
                                 trainingSampleIDs: acceptedPositives.map(\.id).sorted { $0.uuidString < $1.uuidString },
                                 negativeSampleIDs: acceptedNegatives.map(\.id).sorted { $0.uuidString < $1.uuidString },
                                 prototypes: parameters.centers, prototypeSupport: parameters.support,
                                 prototypeThresholds: parameters.thresholds, centroid: parameters.centroid,
                                 state: state, validation: report,
                                 supportsAutomaticMapping: validation.passed == true, prototypeLimit: limit)
    }

    /// A cosine-scale similarity, not a probability or an accuracy percentage.
    /// Learned impostor boundaries only reduce an ambiguous prototype's raw cosine score.
    static func score(_ vector: [Float], model: VoiceLearnedModel) -> Float? {
        guard valid(model), let normalized = normalized(vector) else { return nil }
        return score(normalized, parameters: Parameters(centers: model.prototypes, support: model.prototypeSupport,
                      thresholds: model.prototypeThresholds, centroid: model.centroid, effectiveCount: model.effectiveSampleCount))
    }

    static func valid(_ model: VoiceLearnedModel) -> Bool {
        guard model.dimension == dimension, model.algorithm == "source-balanced-spherical-prototypes-v1",
              model.revision > 0, model.parameterRevision > 0,
              !model.prototypes.isEmpty, model.prototypes.count <= maximumPrototypes,
              model.prototypes.count == model.prototypeThresholds.count,
              model.prototypes.count == model.prototypeSupport.count,
              model.prototypeLimit >= 1, model.prototypeLimit <= maximumPrototypes,
              normalized(model.centroid) != nil,
              model.prototypeThresholds.allSatisfy({ $0.isFinite && $0 >= decisionThreshold && $0 <= 1 + impostorMargin + 0.0001 }),
              model.prototypeSupport.allSatisfy({ $0 > 0 }) else { return false }
        return model.prototypes.allSatisfy { center in
            guard normalized(center) != nil else { return false }
            return abs(dot(center, center) - 1) < 0.01
        }
    }

    private static func examples(_ samples: [VoiceSample]) -> [Example] {
        var seen = Set<UUID>()
        return samples.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { sample in
            guard seen.insert(sample.id).inserted, sample.seconds.isFinite, sample.seconds >= 3,
                  sample.created.timeIntervalSince1970.isFinite, let vector = normalized(sample.vector) else { return nil }
            return Example(id: sample.id, source: sourceKey(sample), vector: vector, seconds: sample.seconds)
        }
    }

    private static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == dimension, vector.allSatisfy(\.isFinite) else { return nil }
        let magnitude = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard magnitude.isFinite, magnitude > 1e-10 else { return nil }
        return vector.map { Float(Double($0) / magnitude) }
    }
    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(Float.zero) { $0 + $1.0 * $1.1 }
    }

    /// Each recording contributes the same total mass. Repeated near-identical chunks share one point.
    private static func points(_ examples: [Example]) -> [Point] {
        let grouped = Dictionary(grouping: examples, by: \.source)
        var all: [Point] = []
        for source in grouped.keys.sorted() {
            var representatives: [Point] = []
            for example in grouped[source]! {
                if let index = representatives.firstIndex(where: { dot($0.vector, example.vector) >= sourceSimilarity }) {
                    // Keep the first deterministic exemplar so repeated copies cannot shift a center.
                    representatives[index].count += 1
                    representatives[index].weight = max(representatives[index].weight, min(12, example.seconds))
                } else {
                    representatives.append(Point(vector: example.vector, weight: min(12, example.seconds), count: 1))
                }
            }
            let total = representatives.reduce(0) { $0 + $1.weight }
            for var point in representatives { point.weight /= max(1e-12, total); all.append(point) }
        }
        return all
    }

    private static func fit(_ examples: [Example], negatives: [Example], limit: Int) -> Parameters {
        let points = points(examples)
        guard !points.isEmpty else { return Parameters(centers: [], support: [], thresholds: [], centroid: [], effectiveCount: 0) }
        func center(_ members: [Point]) -> [Float] {
            var sum = [Double](repeating: 0, count: dimension)
            for member in members { for i in 0..<dimension { sum[i] += Double(member.vector[i]) * member.weight } }
            return normalized(sum.map(Float.init)) ?? members[0].vector
        }
        let centroid = center(points)
        var centers = [centroid]
        if limit > 1 {
            while centers.count < min(limit, points.count) {
                // Deterministic farthest-first seeds capture microphone/room modes, followed by weighted refit.
                var selected: Int?, minimum: Float = 0.90
                for i in points.indices {
                    let nearest = centers.map { dot(points[i].vector, $0) }.max() ?? -1
                    if nearest < minimum { minimum = nearest; selected = i }
                }
                guard let selected else { break }
                centers.append(points[selected].vector)
            }
        }
        var members: [[Point]] = []
        for _ in 0..<16 {
            members = Array(repeating: [], count: centers.count)
            for point in points {
                var winner = 0, best: Float = -.infinity
                for i in centers.indices {
                    let similarity = dot(point.vector, centers[i])
                    if similarity > best { best = similarity; winner = i }
                }
                members[winner].append(point)
            }
            members = members.filter { !$0.isEmpty }
            let updated = members.map(center)
            let converged = updated.count == centers.count && zip(updated, centers).allSatisfy { dot($0.0, $0.1) > 0.999999 }
            centers = updated
            if converged { break }
        }
        // Boundary parameters are trained from other people's labelled examples. A conflicting label
        // can raise a boundary beyond one, yielding a conservative score even at the prototype center.
        let impostors = pointsForNegatives(negatives)
        let thresholds = centers.map { vector -> Float in
            guard let nearest = impostors.map({ dot(vector, $0) }).max() else { return decisionThreshold }
            return max(decisionThreshold, min(1 + impostorMargin, nearest + impostorMargin))
        }
        return Parameters(centers: centers, support: members.map { $0.reduce(0) { $0 + $1.count } },
                          thresholds: thresholds, centroid: centroid, effectiveCount: points.count)
    }

    private static func boundedNegatives(_ examples: [Example], limit: Int) -> [Example] {
        guard examples.count > limit else { return examples }
        let grouped = Dictionary(grouping: examples, by: \.source)
        let sources = grouped.keys.sorted()
        // Select spread-out sources first, then take one chunk per source per round.
        let selected = sources.count <= limit ? sources : (0..<limit).map { sources[$0 * (sources.count - 1) / (limit - 1)] }
        var result: [Example] = [], round = 0
        while result.count < limit {
            var added = false
            for source in selected where result.count < limit {
                let values = grouped[source]!
                if round < values.count { result.append(values[round]); added = true }
            }
            if !added { break }; round += 1
        }
        return result
    }

    private static func pointsForNegatives(_ examples: [Example]) -> [[Float]] {
        // Each person already has a bounded source-balanced selection. Repeated negatives keep
        // identical max-similarity constraints, so global quadratic duplicate comparison adds no value.
        examples.map(\.vector)
    }

    private static func score(_ vector: [Float], parameters: Parameters) -> Float {
        let result = zip(parameters.centers, parameters.thresholds).map {
            dot(vector, $0.0) - max(0, $0.1 - decisionThreshold)
        }.max() ?? -1
        return max(-1, min(1, result))
    }

    private static func evaluate(positives: [Example], negativesByPerson: [[Example]],
                                 baselinePositives: [Example], baselineNegatives: [Example], baselineLimit: Int) -> VoiceLearningValidation {
        let sources = Array(Set(positives.map(\.source))).sorted()
        let usableNegatives = negativesByPerson.filter { Set($0.map(\.source)).count >= 2 }
        var report = VoiceLearningValidation(positiveRecall: nil, falseAcceptRate: nil,
                         baselinePositiveRecall: nil, baselineFalseAcceptRate: nil,
                         heldOutPositiveCount: 0, heldOutNegativeCount: 0, sourceFoldCount: 0,
                         passed: nil, note: "독립된 본인 녹음 3개와 다른 사람의 독립 녹음 2개부터 출처별 검증을 계산합니다.")
        guard sources.count >= 3 else { return report }
        // With one registered identity, measure own-voice recall only; impostor acceptance stays unmeasured.
        let selectedSources: [String] = sources.count <= 6 ? sources : (0..<6).map { sources[$0 * (sources.count - 1) / 5] }
        var own: [UUID: [Double]] = [:], ownBaseline: [UUID: [Double]] = [:]
        var impostor: [UUID: [Double]] = [:], impostorBaseline: [UUID: [Double]] = [:]
        var ownSources: [UUID: String] = [:], negativeSources: [UUID: String] = [:]
        var comparable = true
        for (fold, heldSource) in selectedSources.enumerated() {
            let heldPositives = positives.filter { $0.source == heldSource }
            let trainingPositives = positives.filter { $0.source != heldSource }
            var trainingNegatives: [Example] = [], heldNegatives: [Example] = []
            for person in negativesByPerson {
                let personSources = Array(Set(person.map(\.source))).sorted()
                if personSources.count >= 2 {
                    let held = personSources[fold % personSources.count]
                    trainingNegatives += person.filter { $0.source != held }
                    heldNegatives += person.filter { $0.source == held }
                } else {
                    trainingNegatives += person
                }
            }
            let basePositives = baselinePositives.filter { $0.source != heldSource }
            let heldNegativeSources = Set(heldNegatives.map(\.source))
            trainingNegatives = trainingNegatives.filter { $0.source != heldSource }
            let baseNegatives = baselineNegatives.filter { $0.source != heldSource && !heldNegativeSources.contains($0.source) }
            let learned = fit(trainingPositives, negatives: trainingNegatives, limit: maximumPrototypes)
            let baseline = fit(basePositives, negatives: baseNegatives, limit: baselineLimit)
            if baseline.centers.isEmpty { comparable = false }
            for example in heldPositives {
                own[example.id, default: []].append(score(example.vector, parameters: learned) >= decisionThreshold ? 1 : 0)
                ownSources[example.id] = example.source
                if !baseline.centers.isEmpty {
                    ownBaseline[example.id, default: []].append(score(example.vector, parameters: baseline) >= decisionThreshold ? 1 : 0)
                }
            }
            for example in heldNegatives {
                impostor[example.id, default: []].append(score(example.vector, parameters: learned) >= decisionThreshold ? 1 : 0)
                negativeSources[example.id] = example.source
                if !baseline.centers.isEmpty {
                    impostorBaseline[example.id, default: []].append(score(example.vector, parameters: baseline) >= decisionThreshold ? 1 : 0)
                }
            }
            report.sourceFoldCount += 1
        }
        // Average per source, then across sources: many chunks from one meeting keep one vote.
        func rate(_ values: [UUID: [Double]], sourceMap: [UUID: String]) -> Double? {
            guard !values.isEmpty else { return nil }
            var sourceValues: [String: [Double]] = [:]
            for (id, results) in values {
                sourceValues[sourceMap[id] ?? id.uuidString, default: []].append(results.reduce(0, +) / Double(results.count))
            }
            return sourceValues.values.map { $0.reduce(0, +) / Double($0.count) }.reduce(0, +) / Double(sourceValues.count)
        }
        report.positiveRecall = rate(own, sourceMap: ownSources)
        report.falseAcceptRate = rate(impostor, sourceMap: negativeSources)
        report.heldOutPositiveCount = own.count
        report.heldOutNegativeCount = impostor.count
        if comparable {
            report.baselinePositiveRecall = rate(ownBaseline, sourceMap: ownSources)
            report.baselineFalseAcceptRate = rate(impostorBaseline, sourceMap: negativeSources)
        }
        guard !usableNegatives.isEmpty, comparable,
              let recall = report.positiveRecall, let falseAccept = report.falseAcceptRate,
              let oldRecall = report.baselinePositiveRecall, let oldFalseAccept = report.baselineFalseAcceptRate else {
            report.note = usableNegatives.isEmpty
                ? "본인 녹음을 출처별로 분리해 재인식률을 계산했습니다. 다른 사람의 독립 녹음 2개부터 오인 수락률을 함께 검증합니다."
                : "출처별 검증을 계산했습니다. 비교 모델에 독립 녹음이 더 모이면 이전 판정과 개선 여부를 비교합니다."
            return report
        }
        report.passed = recall + 1e-9 >= oldRecall && falseAccept <= oldFalseAccept + 1e-9 && recall >= 0.60 && falseAccept <= 0.10
        report.note = report.passed == true
            ? "출처별 교차 검증에서 본인 재인식률과 다른 사람의 오인 수락률이 비교 기준을 충족했습니다. 수치는 등록된 검증 자료의 결과입니다."
            : "출처별 교차 검증에서 기존 판정 보존 기준 또는 본인 재인식 60%·오인 수락 10% 기준을 추가 확인해야 합니다."
        return report
    }
}
