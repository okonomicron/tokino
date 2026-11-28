import Foundation
import Observation
import TokinoKit

/// Drives natural-language photo search.
///
/// The interesting logic is not here: tokenizing is `CLIPTokenizer`, ranking is
/// `SimilaritySearch`, filtering is `AssetCriteriaFilter` — all in TokinoKit and
/// all tested on Linux. This type sequences them, debounces typing, and makes
/// sure a slow query cannot overwrite a newer one's results.
@MainActor
@Observable
final class SearchModel {

    enum State: Equatable {
        case idle
        case searching
        case results([SearchResult])
        /// No hits, with the reason when the filters explain it. "No photos in
        /// that date range" is far more useful than an empty grid.
        case empty(explanation: String?)
        case failed(String)
    }

    var query: String = "" {
        didSet { scheduleSearch() }
    }
    private(set) var state: State = .idle
    var criteria = PhotoSelectionCriteria()

    /// Injected rather than constructed here, because loading parses about
    /// 1.4 MB of vocabulary and merges. One instance per app launch, not one
    /// per search.
    private let tokenizer: CLIPTokenizer?
    private let embedQuery: @Sendable ([Int]) async throws -> [Float]
    /// Expected to serve a cached snapshot. Reading every vector back from
    /// SQLite on each keystroke would be tens of megabytes of I/O per
    /// character typed.
    private let loadCandidates: @Sendable () async throws -> [SearchCandidate]
    private let resultLimit: Int

    /// The in-flight search. Cancelled when a newer keystroke arrives, so a
    /// slow query cannot land after a faster later one and show stale results.
    private var searchTask: Task<Void, Never>?

    /// Long enough that typing a word does not fire several searches, short
    /// enough to feel immediate.
    private let debounce: Duration = .milliseconds(250)

    init(
        tokenizer: CLIPTokenizer?,
        embedQuery: @escaping @Sendable ([Int]) async throws -> [Float],
        loadCandidates: @escaping @Sendable () async throws -> [SearchCandidate],
        resultLimit: Int = 60
    ) {
        self.tokenizer = tokenizer
        self.embedQuery = embedQuery
        self.loadCandidates = loadCandidates
        self.resultLimit = resultLimit
    }

    private func scheduleSearch() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            return
        }

        searchTask = Task { [weak self] in
            // Debounce before any work, so typing does not run the text tower
            // once per character.
            try? await Task.sleep(for: self?.debounce ?? .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.performSearch(trimmed)
        }
    }

    private func performSearch(_ text: String) async {
        guard let tokenizer else {
            state = .failed("The search model is unavailable.")
            return
        }

        state = .searching
        do {
            let tokens = tokenizer.tokenize(text)
            let vector = try await embedQuery(tokens)
            guard !Task.isCancelled else { return }

            let candidates = try await loadCandidates()
            guard !Task.isCancelled else { return }

            let admitted = AssetCriteriaFilter.apply(to: candidates, criteria: criteria)
            let results = SimilaritySearch.rank(
                query: vector,
                candidates: admitted,
                limit: resultLimit
            )

            guard !Task.isCancelled else { return }

            if results.isEmpty {
                let diagnosis = EmptyResultDiagnosis.diagnose(
                    candidates: candidates,
                    admitted: admitted,
                    criteria: criteria
                )
                state = .empty(explanation: Self.explain(diagnosis))
            } else {
                state = .results(results)
            }
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Turns the diagnosis into a sentence.
    ///
    /// The decision of *which* situation applies is `EmptyResultDiagnosis` in
    /// TokinoKit, where it is tested on Linux. This is only the wording.
    static func explain(_ diagnosis: EmptyResultDiagnosis) -> String? {
        switch diagnosis {
        case .nothingIndexed:
            return "No photos have been indexed yet."
        case .noGoodMatch:
            // Nothing to explain: the user should try different words.
            return nil
        case .everythingFiltered(let reason):
            switch reason {
            case .excludedByUser:
                return "Every matching photo has been excluded from Tokino."
            case .mediaKindNotWanted:
                return "No photos of the selected media type."
            case .beforeEarliestDate, .afterLatestDate:
                return "No photos in the selected date range."
            case .missingDateButDateFiltered:
                return "The photos found have no date, so the date filter excluded them."
            case .outsideRadius:
                return "No photos within the selected area."
            case .missingCoordinateButGeoFiltered:
                return "The photos found have no location, so the area filter excluded them."
            case .notInRequiredAlbum:
                return "No photos in the selected albums."
            case .inExcludedAlbum:
                return "Every matching photo is in an excluded album."
            case .belowQualityFloor:
                return "No photos met the quality threshold."
            }
        }
    }

    /// Assigning `query` triggers `didSet`, which resets the state to idle for
    /// an empty string, so this does not set `state` itself.
    func clear() {
        query = ""
    }
}
