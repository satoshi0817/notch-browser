import XCTest

/// No named suite is ever passed to Foundation. All preference operations terminate here.
/// The inherited unnamed init is also used by the existing shortcut defaults double.
/// Only dictionary storage below is used; no superclass preference method is called.
final class InMemoryDefaults: UserDefaults {
    var suite = ""
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    private var domains: [String: [String: Any]] = [:]
    private var volatile: [String: [String: Any]] = [:]
    private let lock = NSRecursiveLock()

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    override func object(forKey key: String) -> Any? { locked { values[key] ?? registered[key] } }
    override func set(_ value: Any?, forKey key: String) { locked { values[key] = value } }
    override func removeObject(forKey key: String) { locked { values[key] = nil } }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: URL?, forKey key: String) { set(value as Any?, forKey: key) }
    override func bool(forKey key: String) -> Bool {
        (object(forKey: key) as? NSNumber)?.boolValue ?? (object(forKey: key) as? NSString)?.boolValue ?? false
    }
    override func integer(forKey key: String) -> Int {
        (object(forKey: key) as? NSNumber)?.intValue ?? (object(forKey: key) as? NSString)?.integerValue ?? 0
    }
    override func float(forKey key: String) -> Float {
        (object(forKey: key) as? NSNumber)?.floatValue ?? (object(forKey: key) as? NSString)?.floatValue ?? 0
    }
    override func double(forKey key: String) -> Double {
        (object(forKey: key) as? NSNumber)?.doubleValue ?? (object(forKey: key) as? NSString)?.doubleValue ?? 0
    }
    override func string(forKey key: String) -> String? {
        (object(forKey: key) as? String) ?? (object(forKey: key) as? NSNumber)?.stringValue
    }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func url(forKey key: String) -> URL? { object(forKey: key) as? URL }
    override func dictionaryRepresentation() -> [String: Any] {
        locked { registered.merging(values) { _, value in value } }
    }
    override func register(defaults: [String: Any]) {
        locked { registered.merge(defaults) { _, value in value } }
    }
    override func persistentDomain(forName name: String) -> [String: Any]? {
        locked { name == suite ? values : domains[name] }
    }
    override func setPersistentDomain(_ domain: [String: Any], forName name: String) {
        locked { if name == suite { values = domain } else { domains[name] = domain } }
    }
    override func removePersistentDomain(forName name: String) {
        locked { if name == suite { values = [:] } else { domains[name] = nil } }
    }
    override var volatileDomainNames: [String] { locked { Array(volatile.keys) } }
    override func volatileDomain(forName name: String) -> [String: Any] { locked { volatile[name] ?? [:] } }
    override func setVolatileDomain(_ domain: [String: Any], forName name: String) { locked { volatile[name] = domain } }
    override func removeVolatileDomain(forName name: String) { locked { volatile[name] = nil } }
    override func addSuite(named suiteName: String) {}
    override func removeSuite(named suiteName: String) {}
    override func synchronize() -> Bool { true }
}

/// Single entry point for test preference storage. Names are dictionary labels only.
enum TestDefaults {
    static func plistURL(_ suite: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent(suite + ".plist")
    }

    static func make(_ suite: String = UUID().uuidString, test: XCTestCase) -> UserDefaults {
        let defaults = InMemoryDefaults()
        defaults.suite = suite
        // Retain through teardown, exercising the same lifetime as the former suite helper.
        test.addTeardownBlock { _ = defaults.synchronize() }
        return defaults
    }
}
