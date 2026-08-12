import Foundation

struct HerdPulseRegistrationRetryPolicy: Sendable {
    static let standard = HerdPulseRegistrationRetryPolicy()

    private let delays: [Duration]

    init(delays: [Duration] = [
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(15),
        .seconds(30),
    ]) {
        self.delays = delays
    }

    func delay(afterFailure failureCount: Int) -> Duration {
        guard !delays.isEmpty else { return .seconds(30) }
        let index = min(max(failureCount - 1, 0), delays.count - 1)
        return delays[index]
    }

    func shouldRetry(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL, .userAuthenticationRequired,
                 .appTransportSecurityRequiresSecureConnection:
                return false
            default:
                return true
            }
        }
        if case let APIError.server(status, _) = error {
            return status == 408 || status == 429 || status >= 500
        }
        return false
    }
}
