struct HerdrHapticPulse: Equatable, Sendable {
    private(set) var sequence = 0
    private(set) var event: HerdrHaptic = .selection

    mutating func fire(_ event: HerdrHaptic) {
        self.event = event
        sequence &+= 1
    }
}
