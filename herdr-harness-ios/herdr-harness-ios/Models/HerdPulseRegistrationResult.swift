import Foundation

enum HerdPulseAPNsCapability: Equatable, Sendable {
    case configured
    case unavailable
    case unknown
}

enum HerdPulseRegistrationAttempt: Equatable, Sendable {
    case succeeded(HerdPulseAPNsCapability)
    case failed(willRetry: Bool, retryDelay: Duration?)
}
