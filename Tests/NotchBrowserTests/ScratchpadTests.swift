import XCTest
@testable import NotchBrowser

final class ScratchpadTests: XCTestCase {
    func testNotesPersistWithoutMixingProfilesAndDeletionIsScoped() {
        let suite = "NotchBrowserTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        let store = ScratchpadStore(defaults: defaults)
        store.save("仕事のメモ\nhttps://example.com", for: first)
        store.save("個人のメモ", for: second)
        let reopened = ScratchpadStore(defaults: defaults)
        XCTAssertEqual(reopened.text(for: first), "仕事のメモ\nhttps://example.com")
        XCTAssertEqual(reopened.text(for: second), "個人のメモ")
        reopened.remove(for: first)
        XCTAssertEqual(reopened.text(for: first), "")
        XCTAssertEqual(reopened.text(for: second), "個人のメモ")
    }
}
