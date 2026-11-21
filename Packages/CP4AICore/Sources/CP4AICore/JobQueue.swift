import Foundation

/// A bounded queue for dynamically-created jobs.
///
/// Each worker executes one job at a time on its own thread; jobs may enqueue
/// more jobs (for example, a Pandoc extraction job adds its OCR jobs).  The
/// queue is drained only when every dynamic job has finished.
final class JobQueue {
    private let operations = OperationQueue()
    private let condition = NSCondition()
    private var pending = 0

    init(maxConcurrent: Int) {
        operations.maxConcurrentOperationCount = max(1, maxConcurrent)
        operations.qualityOfService = .userInitiated
    }

    func add(_ job: @escaping () -> Void) {
        condition.lock()
        pending += 1
        condition.unlock()

        operations.addOperation { [weak self] in
            job()
            self?.finishOne()
        }
    }

    private func finishOne() {
        condition.lock()
        pending -= 1
        if pending == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    /// Block until the queue, including jobs enqueued while draining, is empty.
    func drain() {
        condition.lock()
        while pending > 0 {
            condition.wait()
        }
        condition.unlock()
        operations.waitUntilAllOperationsAreFinished()
    }
}
