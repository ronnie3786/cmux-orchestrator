import Foundation

struct ActiveServerConnection: Equatable, Sendable {
    let configuration: ServerConfiguration
    let generation: Int
}
