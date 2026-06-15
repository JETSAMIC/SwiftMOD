import Testing
@testable import SwiftMOD

// Placeholder smoke test. Keeps `swift test` green from the first commit so
// CI / pre-merge gates have something to run before the real parser and
// mixer suites land.

@Test func packageBootstrap() {
    #expect(SwiftMOD.version == "0.1.0")
}
