import Foundation

struct PushDeviceBody: Encodable, Sendable {
    let deviceToken: String
    let bundleId: String
    let environment: String
    var machineId: String = ""
}
