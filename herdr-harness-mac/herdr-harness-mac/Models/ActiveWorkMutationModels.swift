import Foundation

struct ActiveWorkItemEnvelope: Decodable, Sendable {
    let ok: Bool
    let item: ActiveWorkItem
    let created: Bool?
    let generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case item
        case created
        case generatedAt = "generated_at"
    }
}

struct ActiveWorkCreateItemRequest: Encodable, Sendable {
    let kind: String
    let title: String
    let summary: String
    let currentStageKey: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case title
        case summary
        case currentStageKey = "current_stage_key"
    }
}

struct ActiveWorkTransitionRequest: Encodable, Sendable {
    let toStageKey: String
    let expectedRevision: Int
    let note: String?
    let attention: String
    let checkpointState: String?

    enum CodingKeys: String, CodingKey {
        case toStageKey = "to_stage_key"
        case expectedRevision = "expected_revision"
        case note
        case attention
        case checkpointState = "checkpoint_state"
    }
}

struct ActiveWorkPatchItemRequest: Encodable, Sendable {
    let lifecycle: String
    let expectedRevision: Int

    enum CodingKeys: String, CodingKey {
        case lifecycle
        case expectedRevision = "expected_revision"
    }
}
