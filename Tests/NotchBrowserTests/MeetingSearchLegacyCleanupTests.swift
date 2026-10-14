import Foundation
import Darwin
import XCTest
@testable import NotchBrowser

final class MeetingSearchLegacyCleanupTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let resolved = try XCTUnwrap(fm.temporaryDirectory.path.withCString { Darwin.realpath($0, nil) })
        defer { Darwin.free(resolved) }
        let home = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = MeetingSearchLegacyCleanup.target(home: home)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try body(home, target)
    }

    func testDeletesOnlyExactLegacyDirectoryAndPreservesSiblingsAndParents() throws {
        try fixture { home, target in
            let parent = target.deletingLastPathComponent()
            let sibling = parent.appendingPathComponent("meetings.json")
            try Data("keep".utf8).write(to: sibling)
            try Data("old cache".utf8).write(to: target.appendingPathComponent("cache.json"))
            XCTAssertTrue(try MeetingSearchLegacyCleanup.remove(target, home: home))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))
            XCTAssertEqual(try String(contentsOf: sibling), "keep")
            XCTAssertFalse(try MeetingSearchLegacyCleanup.remove(target, home: home))
        }
    }

    func testRejectsParentsSiblingsChildrenOtherHomesAndTraversal() throws {
        try fixture { home, target in
            let parent = target.deletingLastPathComponent()
            for candidate in [home, parent, parent.deletingLastPathComponent(),
                              parent.appendingPathComponent("meeting-search-backup"),
                              target.appendingPathComponent("cache.json"),
                              parent.appendingPathComponent("other/../meeting-search"),
                              MeetingSearchLegacyCleanup.target(home: home.appendingPathComponent("other"))] {
                XCTAssertFalse(try MeetingSearchLegacyCleanup.remove(candidate, home: home), candidate.path)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testRejectsTargetSymlinkWithoutDeletingLinkOrDestination() throws {
        try fixture { home, target in
            let destination = home.appendingPathComponent("keep")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
            XCTAssertFalse(try MeetingSearchLegacyCleanup.remove(target, home: home))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), destination.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testRejectsSymlinkedParentAndKeepsRealTree() throws {
        try fixture { home, target in
            let parent = target.deletingLastPathComponent()
            let relocated = home.appendingPathComponent("relocated")
            try FileManager.default.moveItem(at: parent, to: relocated)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: relocated)
            XCTAssertFalse(try MeetingSearchLegacyCleanup.remove(target, home: home))
            XCTAssertTrue(FileManager.default.fileExists(atPath: relocated.appendingPathComponent("meeting-search").path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: parent.path), relocated.path)
        }
    }

    func testRejectsSymlinkedAncestorAboveHomeAndKeepsLinkAndContents() throws {
        try fixture { home, target in
            let fm = FileManager.default
            let realAncestor = home.appendingPathComponent("real-ancestor", isDirectory: true)
            let realHome = realAncestor.appendingPathComponent("home", isDirectory: true)
            let realTarget = MeetingSearchLegacyCleanup.target(home: realHome)
            try fm.createDirectory(at: realTarget, withIntermediateDirectories: true)
            let cache = realTarget.appendingPathComponent("cache.json")
            try Data("keep".utf8).write(to: cache)

            let ancestorLink = home.appendingPathComponent("ancestor-link", isDirectory: true)
            try fm.createSymbolicLink(at: ancestorLink, withDestinationURL: realAncestor)
            let linkedHome = ancestorLink.appendingPathComponent("home", isDirectory: true)
            let linkedTarget = MeetingSearchLegacyCleanup.target(home: linkedHome)

            XCTAssertFalse(try MeetingSearchLegacyCleanup.remove(linkedTarget, home: linkedHome))
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: ancestorLink.path), realAncestor.path)
            XCTAssertTrue(fm.fileExists(atPath: realHome.path))
            XCTAssertTrue(fm.fileExists(atPath: realTarget.path))
            XCTAssertEqual(try String(contentsOf: cache), "keep")
            XCTAssertTrue(fm.fileExists(atPath: target.path))
        }
    }

    func testRejectsNestedSymlinksAndRegularFile() throws {
        try fixture { home, target in
            let link = target.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("missing"))
            XCTAssertFalse(try MeetingSearchLegacyCleanup.remove(target, home: home))
            XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
            try FileManager.default.removeItem(at: target)
            try Data("keep".utf8).write(to: target)
            XCTAssertFalse(try MeetingSearchLegacyCleanup.remove(target, home: home))
            XCTAssertEqual(try String(contentsOf: target), "keep")
        }
    }
}
