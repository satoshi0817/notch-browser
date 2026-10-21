import XCTest
@testable import NotchBrowser

final class Notch024FocusTests: XCTestCase {
    func testDetailTargetRequiresOtherFieldInSameDetailGroup() {
        let group = UUID()
        let otherGroup = UUID()
        func target(_ source: NotionTaskField?, _ candidate: NotionTaskField?,
                    sourceGroup: UUID?, candidateGroup: UUID?,
                    sourceDetail: Bool = true, candidateDetail: Bool = true) -> Bool {
            NotionDetailFocusRules.isTarget(sourceField: source, sourceGroup: sourceGroup,
                sourceHandlesDetailTab: sourceDetail, candidateField: candidate,
                candidateGroup: candidateGroup, candidateHandlesDetailTab: candidateDetail)
        }
        XCTAssertTrue(target(.status, .due, sourceGroup: group, candidateGroup: group))
        XCTAssertTrue(target(.due, .status, sourceGroup: group, candidateGroup: group))
        XCTAssertFalse(target(.status, .status, sourceGroup: group, candidateGroup: group))
        XCTAssertFalse(target(.due, .due, sourceGroup: group, candidateGroup: group))
        XCTAssertFalse(target(.due, .status, sourceGroup: group, candidateGroup: group, candidateDetail: false)) // List badge.
        XCTAssertFalse(target(.status, .due, sourceGroup: group, candidateGroup: group, sourceDetail: false))
        XCTAssertFalse(target(.due, .status, sourceGroup: group, candidateGroup: otherGroup))
        XCTAssertFalse(target(.due, .status, sourceGroup: group, candidateGroup: nil))
        XCTAssertFalse(target(.due, .status, sourceGroup: nil, candidateGroup: nil))
        XCTAssertFalse(target(nil, .status, sourceGroup: group, candidateGroup: group))
        XCTAssertFalse(target(.due, nil, sourceGroup: group, candidateGroup: group))
    }
}
