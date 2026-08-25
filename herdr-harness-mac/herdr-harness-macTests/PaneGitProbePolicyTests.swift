import Testing
@testable import herdr_harness_mac

struct PaneGitProbePolicyTests {
    @Test("A valid repository response exposes Git")
    func validRepository() {
        let availability = PaneGitProbePolicy.availability(
            after: .status(ok: true, rootPath: "  /repo  "),
            preserving: .checking
        )

        #expect(availability == .available)
    }

    @Test("Missing repositories remain eligible for a later probe")
    func missingRepository() {
        let availability = PaneGitProbePolicy.availability(
            after: .notFound,
            preserving: .available
        )

        #expect(availability == .unavailable)
        #expect(PaneGitProbePolicy.refreshInterval == .seconds(15))
    }

    @Test("Malformed success responses do not expose Git")
    func malformedResponse() {
        let availability = PaneGitProbePolicy.availability(
            after: .status(ok: true, rootPath: " \n "),
            preserving: .available
        )

        #expect(availability == .unavailable)
    }

    @Test("Transient failures preserve the last known capability")
    func transientFailure() {
        #expect(
            PaneGitProbePolicy.availability(
                after: .transientFailure,
                preserving: .available
            ) == .available
        )
        #expect(
            PaneGitProbePolicy.availability(
                after: .transientFailure,
                preserving: .unavailable
            ) == .unavailable
        )
        #expect(
            PaneGitProbePolicy.availability(
                after: .transientFailure,
                preserving: .checking
            ) == .checking
        )
    }
}
