import Foundation

/// A newer tab selection supersedes only the previous focus operation, never
/// profile launch, configuration, or the native task itself.
@MainActor
final class LatestFocusRequest {
    private var current: Task<Void, Error>?

    func run(_ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        current?.cancel()
        let task = Task { try Task.checkCancellation(); try await operation() }
        current = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
