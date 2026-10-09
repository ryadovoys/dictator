import XCTest
@testable import Dictator

@MainActor
final class DictationCancellationTests: XCTestCase {
    func testCancelledRecognitionCannotDeliverALateResult() async {
        let job = DictationTranscription()
        let recognition = SuspendedRecognition()
        var delivered = [String]()
        var completed = false
        let work = job.start(recognize: { try await recognition.run() }, deliver: {
            delivered.append($0); return .inserted
        }, completed: { _, _ in completed = true }, failed: { _ in XCTFail("Cancelled job reported an error") })
        await fulfillment(of: [recognition.started], timeout: 2)
        job.cancel()
        recognition.finish(.success("abandoned text")) // Deliberately ignores Swift cancellation.
        await work.value
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertFalse(completed)
    }

    func testCancelledFailureCannotAffectANewerDictation() async {
        let job = DictationTranscription()
        let old = SuspendedRecognition()
        let current = SuspendedRecognition()
        var delivered = [String]()
        var completed = [String]()
        let oldWork = job.start(recognize: { try await old.run() }, deliver: {
            delivered.append($0); return .inserted
        }, completed: { text, _ in completed.append(text) }, failed: { _ in XCTFail("Stale error escaped") })
        await fulfillment(of: [old.started], timeout: 2)
        job.cancel()
        let currentWork = job.start(recognize: { try await current.run() }, deliver: {
            delivered.append($0); return .inserted
        }, completed: { text, _ in completed.append(text) }, failed: { _ in XCTFail("New job failed") })
        await fulfillment(of: [current.started], timeout: 2)
        old.finish(.failure(NSError(domain: "late model failure", code: 1)))
        await oldWork.value
        current.finish(.success("new text"))
        await currentWork.value
        XCTAssertEqual(delivered, ["new text"])
        XCTAssertEqual(completed, ["new text"])
    }

    func testLateSuccessCannotReplaceTheNewerResult() async {
        let job = DictationTranscription()
        let old = SuspendedRecognition()
        var delivered = [String]()
        var completed = [String]()
        let oldWork = job.start(recognize: { try await old.run() }, deliver: {
            delivered.append($0); return .inserted
        }, completed: { text, _ in completed.append(text) }, failed: { _ in XCTFail("Stale error escaped") })
        await fulfillment(of: [old.started], timeout: 2)
        let newWork = job.start(recognize: { "new text" }, deliver: {
            delivered.append($0); return .copiedNoAccessibility
        }, completed: { text, result in
            XCTAssertEqual(result, .copiedNoAccessibility)
            completed.append(text)
        }, failed: { _ in XCTFail("New job failed") })
        await newWork.value
        old.finish(.success("old text"))
        await oldWork.value
        XCTAssertEqual(delivered, ["new text"])
        XCTAssertEqual(completed, ["new text"])
    }

    func testCancelDuringPasteConfirmationDoesNotCompleteTheOldJob() async {
        let job = DictationTranscription()
        let delivery = SuspendedRecognition()
        var completed = false
        let work = job.start(recognize: { "text" }, deliver: { _ in
            _ = try await delivery.run()
            return .inserted
        }, completed: { _, _ in completed = true }, failed: { _ in XCTFail("Cancelled delivery reported an error") })
        await fulfillment(of: [delivery.started], timeout: 2)
        job.cancel()
        delivery.finish(.success("confirmed"))
        await work.value
        XCTAssertFalse(completed)
    }

    func testCurrentFailureIsStillReported() async {
        let job = DictationTranscription()
        var failureCode: Int?
        let work = job.start(recognize: { throw NSError(domain: "model", code: 42) }, deliver: { _ in
            XCTFail("Failed recognition delivered text"); return .inserted
        }, completed: { _, _ in XCTFail("Failed recognition completed") }, failed: {
            failureCode = ($0 as NSError).code
        })
        await work.value
        XCTAssertEqual(failureCode, 42)
    }

    func testCancelledDeliveryNeverTouchesClipboard() async {
        let work = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await FocusInserter.deliver("must not copy", to: nil)
                XCTFail("Cancelled delivery should throw before accessing Accessibility or clipboard")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await work.value
    }
}

/// Models a recognizer (or device shutdown) that resumes even after its task was cancelled.
@MainActor
private final class SuspendedRecognition {
    let started = XCTestExpectation(description: "Operation suspended")
    private var continuation: CheckedContinuation<String, Error>?

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
