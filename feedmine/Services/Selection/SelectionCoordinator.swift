import Foundation

// MARK: - Selection Coordinator
//
// Top-level orchestrator for the unified selection engine.
// Owns the catalog interface, trace logger, and session registry.
// FeedStore delegates to this coordinator instead of implementing
// its own fetch for each mode.

/// Central coordinator for all selection sessions.
/// One instance per app lifecycle, owned by FeedStore.
@MainActor
final class SelectionCoordinator {

    // MARK: - Dependencies

    let catalog: any SelectionCatalogReading
    let traceLogger: SelectionTraceLogger
    let idGenerator: SelectionIDGenerator

    // MARK: - Active sessions

    /// The main feed session. Nil until the first request.
    private(set) var mainSession: SelectionSession?

    /// Additional sessions (source view, search, etc.).
    private var secondarySessions: [SelectionSurface: SelectionSession] = [:]

    // MARK: - Init

    init(
        catalog: any SelectionCatalogReading,
        traceLogger: SelectionTraceLogger = SelectionTraceLogger(),
        idGenerator: SelectionIDGenerator = SelectionIDGenerator()
    ) {
        self.catalog = catalog
        self.traceLogger = traceLogger
        self.idGenerator = idGenerator
    }

    // MARK: - Session management

    /// Submit a new request, creating a new session and cancelling
    /// any existing session for the same surface.
    func submit(_ request: ContentSelectionRequest) -> SelectionSession {
        // Cancel existing session for this surface
        cancelSession(for: request.surface)

        let compiler = makeCompiler()
        let session = SelectionSession(
            request: request,
            compiler: compiler,
            traceLogger: traceLogger
        )

        switch request.surface {
        case .main:
            mainSession = session
        default:
            secondarySessions[request.surface] = session
        }

        // Start the session
        Task { await session.start() }

        return session
    }

    /// Get the active session for a surface, if any.
    func session(for surface: SelectionSurface) -> SelectionSession? {
        switch surface {
        case .main:
            return mainSession
        default:
            return secondarySessions[surface]
        }
    }

    /// Cancel and remove the session for a surface.
    func cancelSession(for surface: SelectionSurface) {
        switch surface {
        case .main:
            mainSession?.cancel()
            mainSession = nil
        default:
            secondarySessions[surface]?.cancel()
            secondarySessions[surface] = nil
        }
    }

    /// Cancel all active sessions.
    func cancelAll() {
        mainSession?.cancel()
        mainSession = nil
        for session in secondarySessions.values {
            session.cancel()
        }
        secondarySessions.removeAll()
    }

    // MARK: - Compiler factory

    private func makeCompiler() -> SelectionCompiler {
        SelectionCompiler(
            catalog: catalog,
            scopeResolver: SourceScopeResolver(),
            sqlCompiler: SQLItemRuleCompiler(),
            taxonomy: .empty,
            userState: .empty
        )
    }

    // MARK: - Trace access

    /// All traces from completed sessions.
    func allTraces() async -> [SelectionTrace] {
        await traceLogger.allTraces()
    }
}
