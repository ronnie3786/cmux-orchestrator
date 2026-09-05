struct QuickVoiceList: Decodable, Sendable {
    let ok: Bool
    let jobs: [QuickVoiceJob]
}
