import Foundation

struct HerdPulseSyncContext: Equatable, Sendable {
    let aggregate: HerdPulseAggregate
    let serverConnection: ActiveServerConnection?
}
