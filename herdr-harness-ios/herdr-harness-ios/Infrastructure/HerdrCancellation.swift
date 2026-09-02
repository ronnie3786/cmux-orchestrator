import Foundation

enum HerdrCancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        return containsURLCancellation(error as NSError, visited: [])
    }

    private static func containsURLCancellation(
        _ error: NSError,
        visited: Set<ObjectIdentifier>
    ) -> Bool {
        let identifier = ObjectIdentifier(error)
        guard !visited.contains(identifier) else { return false }

        var visited = visited
        visited.insert(identifier)
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            return true
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           containsURLCancellation(underlying, visited: visited) {
            return true
        }

        let multipleUnderlyingErrors = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? []
        return multipleUnderlyingErrors.contains {
            containsURLCancellation($0, visited: visited)
        }
    }
}
