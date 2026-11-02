import Testing
@testable import AgtermLinux

@Suite("Linux primary menu actions")
struct PrimaryMenuTests {
    @Test("all primary menu actions round-trip through their integer raw values")
    @MainActor
    func actionRawValuesRoundTrip() {
        var seenRawValues: Set<Int> = []
        for action in PrimaryMenuAction.allCases {
            #expect(action.rawValue > 0)
            #expect(!seenRawValues.contains(action.rawValue), "duplicate raw value \(action.rawValue)")
            seenRawValues.insert(action.rawValue)
            #expect(PrimaryMenuAction(rawValue: action.rawValue) == action)
        }
    }
}
