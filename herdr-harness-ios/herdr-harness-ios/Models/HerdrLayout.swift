import Foundation

struct HerdrLayout: Codable, Equatable, Hashable, Identifiable, Sendable {
    let workspaceID: String
    let tabID: String
    let focusedPaneID: String?
    let zoomed: Bool
    let area: HerdrLayoutRect
    let panes: [HerdrLayoutPane]
    let splits: [HerdrLayoutSplit]

    var id: String { "\(workspaceID):\(tabID)" }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case focusedPaneID = "focused_pane_id"
        case zoomed
        case area
        case panes
        case splits
    }
}

struct HerdrLayoutRect: Codable, Equatable, Hashable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct HerdrLayoutPane: Codable, Equatable, Hashable, Identifiable, Sendable {
    let paneID: String
    let focused: Bool
    let rect: HerdrLayoutRect

    var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case focused
        case rect
    }
}

struct HerdrLayoutSplit: Codable, Equatable, Hashable, Identifiable, Sendable {
    let path: [Int]?
    let direction: String?
    let ratio: Double?

    var id: String { "\(path ?? [])-\(direction ?? "split")" }
}
