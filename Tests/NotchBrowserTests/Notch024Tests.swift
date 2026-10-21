import XCTest
import CoreFoundation
@testable import NotchBrowser

final class Notch024Tests: XCTestCase {
    func testDueTooltipRequiresExplicitDueAndStoreEditability() {
        let displayOnly = "時刻や終了日のある期日は Notion で変更してください"
        let values: [Bool?] = [nil, false, true]
        for value in values {
            XCTAssertEqual(NotionDueTooltip.text(dueEditable: value, editable: false), displayOnly)
            XCTAssertEqual(NotionDueTooltip.text(dueEditable: value, editable: true),
                           value == true ? "期日を変更" : displayOnly)
        }
    }

    func testMemoryDefaultsNeverCreatesSuitePlistAfterPreferencesFlush() async throws {
        let suite = "NotchBrowserTests.Memory.\(UUID().uuidString)"
        let url = TestDefaults.plistURL(suite)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let defaults = TestDefaults.make(suite, test: self)
        defaults.set("temporary", forKey: "value")
        XCTAssertTrue(defaults.synchronize())
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["value"] as? String, "temporary")
        _ = CFPreferencesAppSynchronize(suite as CFString)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        defaults.removePersistentDomain(forName: suite)
        XCTAssertTrue(defaults.synchronize())
        _ = CFPreferencesAppSynchronize(suite as CFString)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(defaults.dictionaryRepresentation().isEmpty)
    }

    func testMemoryDefaultsCoversInjectedProductionAccessors() {
        let defaults = TestDefaults.make(test: self)
        defaults.register(defaults: ["fallback": "registered"])
        defaults.set(true, forKey: "bool")
        defaults.set(42, forKey: "int")
        defaults.set(1.5, forKey: "double")
        defaults.set(Float(2.5), forKey: "float")
        defaults.set("text", forKey: "string")
        defaults.set(Data([1, 2]), forKey: "data")
        defaults.set(["one"], forKey: "array")
        defaults.set(["key": "value"], forKey: "dictionary")
        let url = URL(string: "https://example.invalid")!
        defaults.set(url, forKey: "url")
        XCTAssertTrue(defaults.bool(forKey: "bool"))
        XCTAssertEqual(defaults.integer(forKey: "int"), 42)
        XCTAssertEqual(defaults.double(forKey: "double"), 1.5)
        XCTAssertEqual(defaults.float(forKey: "float"), 2.5)
        XCTAssertEqual(defaults.string(forKey: "string"), "text")
        XCTAssertEqual(defaults.data(forKey: "data"), Data([1, 2]))
        XCTAssertEqual(defaults.array(forKey: "array")?.count, 1)
        XCTAssertEqual(defaults.stringArray(forKey: "array"), ["one"])
        XCTAssertEqual(defaults.dictionary(forKey: "dictionary")?["key"] as? String, "value")
        XCTAssertEqual(defaults.url(forKey: "url"), url)
        XCTAssertEqual(defaults.object(forKey: "fallback") as? String, "registered")
        defaults.removeObject(forKey: "string")
        XCTAssertNil(defaults.string(forKey: "string"))
        XCTAssertNotNil(defaults.dictionaryRepresentation()["int"])
        defaults.setPersistentDomain(["probe": true], forName: "memory-domain")
        XCTAssertEqual(defaults.persistentDomain(forName: "memory-domain")?["probe"] as? Bool, true)
        defaults.removePersistentDomain(forName: "memory-domain")
        XCTAssertNil(defaults.persistentDomain(forName: "memory-domain"))
    }
}
