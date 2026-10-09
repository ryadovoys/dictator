import Foundation

/// Owns one transcription. An abandoned model call may finish later, but may never deliver
/// text, report an error, or change the state of a newer dictation.
@MainActor
final class DictationTranscription {
    private var generation = UUID()
    private var task: Task<Void, Never>?

    @discardableResult
    func start(
        recognize: @escaping @MainActor () async throws -> String,
        deliver: @escaping @MainActor (String) async throws -> DeliveryResult,
        completed: @escaping @MainActor (String, DeliveryResult) -> Void,
        failed: @escaping @MainActor (Error) -> Void
    ) -> Task<Void, Never> {
        cancel()
        let attempt = generation
        let work = Task { @MainActor in
            do {
                let text = try await recognize()
                guard generation == attempt, !Task.isCancelled else { return }
                // No suspension between the guard and delivery's clipboard/paste operation.
                let result = try await deliver(text)
                guard generation == attempt, !Task.isCancelled else { return }
                task = nil
                completed(text, result)
            } catch {
                guard generation == attempt, !Task.isCancelled else { return }
                task = nil
                failed(error)
            }
        }
        task = work
        return work
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }
}
