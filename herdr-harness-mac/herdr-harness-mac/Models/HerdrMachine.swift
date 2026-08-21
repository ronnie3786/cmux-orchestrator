import Foundation

struct HerdrMachine: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var urlString: String
}
