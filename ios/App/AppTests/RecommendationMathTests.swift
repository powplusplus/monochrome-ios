import XCTest
@testable import App

/// Covers the pure scoring and diversity logic behind autoplay. These are plain
/// value transforms, so they run without networking or a live player.
final class RecommendationMathTests: XCTestCase {

    func testCosineIsZeroRatherThanNaNWhenEitherSideIsEmpty() {
        XCTAssertEqual(RecommendationMath.cosine(["rock": 1], ["rock": 1]), 1, accuracy: 0.0001)
        XCTAssertEqual(RecommendationMath.cosine(["rock": 1], ["jazz": 1]), 0)
        XCTAssertEqual(RecommendationMath.cosine([:], ["rock": 1]), 0)
        XCTAssertEqual(RecommendationMath.cosine(["rock": 1], [:]), 0)
    }

    func testL2NormalizeHandlesAnAllZeroVector() {
        let unit = RecommendationMath.l2Normalize(["a": 3, "b": 4])
        XCTAssertEqual(unit["a"] ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(unit["b"] ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertTrue(RecommendationMath.l2Normalize(["a": 0]).isEmpty)
    }

    func testTagVectorDropsStopwordsAndLowCountTags() {
        let vector = RecommendationMath.buildTagVector(
            trackTags: [("Shoegaze", 100), ("seen live", 100), ("noise", 5)],
            artistTags: [])
        XCTAssertEqual(Array(vector.keys), ["shoegaze"])
    }

    func testTagVectorNormalizesPunctuationAndAmpersands() {
        let vector = RecommendationMath.buildTagVector(
            trackTags: [("Hip-Hop", 90), ("Drum & Bass", 80)], artistTags: [])
        XCTAssertEqual(Set(vector.keys), ["hiphop", "drumandbass"])
    }

    func testArtistTagsWeighHigherWhenTheTrackIsBarelyTagged() {
        let artistTags = [(name: "ambient", count: 100)]
        let wellTagged = RecommendationMath.buildTagVector(
            trackTags: [("rock", 100), ("indie", 100), ("pop", 100)], artistTags: artistTags)
        let barelyTagged = RecommendationMath.buildTagVector(
            trackTags: [("rock", 100)], artistTags: artistTags)

        let wellRatio = (wellTagged["ambient"] ?? 0) / (wellTagged["rock"] ?? 1)
        let barelyRatio = (barelyTagged["ambient"] ?? 0) / (barelyTagged["rock"] ?? 1)
        XCTAssertGreaterThan(barelyRatio, wellRatio)
    }

    func testEnergyReportsZeroConfidenceWhenNoTagMatches() {
        let unknown = RecommendationMath.energy(from: ["somethingunknown": 1])
        XCTAssertEqual(unknown.energy, 0.5)
        XCTAssertEqual(unknown.confidence, 0)

        XCTAssertGreaterThan(RecommendationMath.energy(from: ["drumandbass": 1]).energy,
                             RecommendationMath.energy(from: ["ambient": 1]).energy)
    }

    func testCamelotMappingIncludingFlats() {
        XCTAssertEqual(RecommendationMath.camelot(key: "A", scale: "MINOR"), "8A")
        XCTAssertEqual(RecommendationMath.camelot(key: "C", scale: "MAJOR"), "8B")
        XCTAssertEqual(RecommendationMath.camelot(key: "Bb", scale: "MINOR"), "3A")
        XCTAssertEqual(RecommendationMath.camelot(key: "Db", scale: "MAJOR"), "3B")
        XCTAssertNil(RecommendationMath.camelot(key: nil, scale: "MINOR"))
        XCTAssertNil(RecommendationMath.camelot(key: "H", scale: "MAJOR"))
    }

    func testHarmonicFitScoresIdenticalAdjacentAndRelativeKeys() {
        XCTAssertEqual(RecommendationMath.harmonicFit("8A", "8A"), 1)
        XCTAssertEqual(RecommendationMath.harmonicFit("8A", "8B"), 0.8)
        XCTAssertEqual(RecommendationMath.harmonicFit("8A", "9A"), 0.8)
        XCTAssertEqual(RecommendationMath.harmonicFit("12A", "1A"), 0.8)
        XCTAssertEqual(RecommendationMath.harmonicFit("8A", "2A"), 0.3)
        XCTAssertNil(RecommendationMath.harmonicFit("8A", nil))
    }

    func testBpmProximityGivesHalfAndDoubleTimeCredit() {
        XCTAssertEqual(RecommendationMath.bpmProximity(128, 128), 1)
        XCTAssertEqual(RecommendationMath.bpmProximity(174, 87), 1)
        XCTAssertEqual(RecommendationMath.bpmProximity(87, 174), 1)
        XCTAssertLessThan(RecommendationMath.bpmProximity(100, 145) ?? 1, 0.2)
        XCTAssertNil(RecommendationMath.bpmProximity(nil, 120))
        XCTAssertNil(RecommendationMath.bpmProximity(120, nil))
    }

    func testBandBoundaries() {
        XCTAssertEqual(RecommendationMath.popBand(19), 0)
        XCTAssertEqual(RecommendationMath.popBand(20), 1)
        XCTAssertEqual(RecommendationMath.popBand(80), 4)
        XCTAssertNil(RecommendationMath.popBand(nil))

        XCTAssertEqual(RecommendationMath.durBandIndex(119), 0)
        XCTAssertEqual(RecommendationMath.durBandIndex(120), 1)
        XCTAssertEqual(RecommendationMath.durBandIndex(420), 3)
        XCTAssertNil(RecommendationMath.durBandIndex(0))
    }

    func testUnknownReleaseYearScoresNeutral() {
        XCTAssertEqual(RecommendationMath.eraProximity(nil, 2000), 0.5)
        XCTAssertEqual(RecommendationMath.eraProximity(2000, 2000), 1)
        XCTAssertEqual(RecommendationMath.eraProximity(1960, 2000), 0)
    }

    func testCombineRenormalizesWhenTermsAreMissing() {
        var all: [String: Double?] = [:]
        for (name, _) in RecommendationMath.weights { all[name] = 0.5 }
        XCTAssertEqual(RecommendationMath.combine(terms: all), 0.5, accuracy: 0.0001)

        // No tags, no BPM, no key: the surviving terms must still reach 1.0.
        var partial: [String: Double?] = [:]
        for (name, _) in RecommendationMath.weights { partial[name] = 1 }
        partial["tagSimilarity"] = Double?.none
        partial["bpmProximity"] = Double?.none
        partial["harmonicFit"] = Double?.none
        XCTAssertEqual(RecommendationMath.combine(terms: partial), 1, accuracy: 0.0001)

        XCTAssertEqual(RecommendationMath.combine(terms: [:]), 0)
    }

    func testCombineSubtractsPenaltiesAndClamps() {
        let penalised = RecommendationMath.combine(
            terms: ["artistProximity": 0],
            penalties: ["dislikeSimilarity": 1, "artistPenalty": 1])
        XCTAssertEqual(penalised, -0.35, accuracy: 0.0001)

        let floored = RecommendationMath.combine(
            terms: ["artistProximity": 0],
            penalties: ["dislikeSimilarity": 10, "artistPenalty": 10])
        XCTAssertEqual(floored, -1)
    }

    private func candidate(_ id: String, artist: String, score: Double,
                           tags: [String: Double] = [:],
                           explore: Bool = false) -> RecommendationMath.Candidate {
        RecommendationMath.Candidate(id: id, score: score, tags: tags, bpm: nil,
                                     artistID: artist, albumID: "alb-\(id)", isExplore: explore)
    }

    func testDiversityCapsOneArtistAtTwoPerTen() {
        var pool = (0..<5).map { candidate("hog\($0)", artist: "A", score: 1) }
        pool += (0..<5).map { candidate("other\($0)", artist: "B\($0)", score: 0.1) }

        let selected = RecommendationMath.selectDiverse(pool, count: 5, exploreRatio: 0)
        XCTAssertEqual(selected.count, 5)
        XCTAssertEqual(selected.filter { $0.artistID == "A" }.count, 2)
    }

    func testDiversityCountsTheAlreadyQueuedTail() {
        let tail = [candidate("q1", artist: "A", score: 1), candidate("q2", artist: "A", score: 1)]
        let pool = [candidate("c1", artist: "A", score: 1), candidate("c2", artist: "B", score: 0.1)]

        let selected = RecommendationMath.selectDiverse(pool, count: 1, queueTail: tail, exploreRatio: 0)
        XCTAssertEqual(selected.first?.artistID, "B")
    }

    func testMMRPrefersADissimilarCandidateOverANearDuplicate() {
        let pool = [
            candidate("a", artist: "A", score: 1.0, tags: ["techno": 1]),
            candidate("b", artist: "B", score: 0.95, tags: ["techno": 1]),
            candidate("c", artist: "C", score: 0.9, tags: ["folk": 1]),
        ]
        let selected = RecommendationMath.selectDiverse(pool, count: 2, lambda: 0.5, exploreRatio: 0)
        XCTAssertEqual(selected.map(\.id), ["a", "c"])
    }

    func testExplorationQuotaIsFilledEvenWhenExploreCandidatesScoreWorst() {
        var pool = (0..<8).map { candidate("known\($0)", artist: "K\($0)", score: 1) }
        pool += [candidate("fresh1", artist: "F1", score: 0.01, explore: true),
                 candidate("fresh2", artist: "F2", score: 0.01, explore: true)]

        let selected = RecommendationMath.selectDiverse(pool, count: 10, exploreRatio: 0.2)
        XCTAssertGreaterThanOrEqual(selected.filter(\.isExplore).count, 2)
    }

    func testDiversityRelaxesRatherThanStallingOnAHomogeneousPool() {
        let pool = (0..<6).map { index in
            RecommendationMath.Candidate(id: "same\(index)", score: 1, tags: [:], bpm: nil,
                                         artistID: "A", albumID: "one", isExplore: false)
        }
        XCTAssertEqual(RecommendationMath.selectDiverse(pool, count: 5).count, 5)
        XCTAssertEqual(RecommendationMath.selectDiverse([], count: 5).count, 0)
    }

    func testResolutionNormalizationStripsEditionsFeaturesAndDiacritics() {
        XCTAssertEqual(RecommendationMath.normalizeForResolution("Paranoid Android - 2009 Remaster"),
                       RecommendationMath.normalizeForResolution("Paranoid Android"))
        XCTAssertEqual(RecommendationMath.normalizeForResolution("Song (feat. X)"), "song")
        XCTAssertEqual(RecommendationMath.normalizeForResolution("Song [ft. Someone]"), "song")
        XCTAssertEqual(RecommendationMath.normalizeForResolution("Sigur Ros"), "sigurros")
        XCTAssertEqual(RecommendationMath.resolveKey(artist: "Radiohead", title: "Creep"),
                       "radiohead|creep")
    }

    func testTrackMappingReadsBpmKeyAndPopularity() throws {
        let track = try XCTUnwrap(ModelMapper.track([
            "id": 5, "title": "Song", "artist": ["id": 1, "name": "A"],
            "bpm": 174, "key": "Bb", "keyScale": "MINOR", "popularity": 71,
            "streamStartDate": "1993-04-05",
        ]))
        XCTAssertEqual(track.bpm, 174)
        XCTAssertEqual(track.camelot, "3A")
        XCTAssertEqual(track.popularity, 71)
        XCTAssertEqual(track.releaseYear, 1993)
    }

    func testTrackDecodesWhenPersistedBeforeTheAutoplayFieldsExisted() throws {
        // Queues saved by an older build must still restore.
        let legacy = Data("""
        {"id":"tidal:1","title":"Song","artist":{"id":"1","name":"A"},
         "duration":200,"explicit":false,"provider":"tidal"}
        """.utf8)
        let track = try JSONDecoder().decode(Track.self, from: legacy)
        XCTAssertEqual(track.id, "tidal:1")
        XCTAssertNil(track.bpm)
        XCTAssertNil(track.recSource)
    }
}
