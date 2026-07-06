import XCTest
@testable import MacDirStat

@MainActor
final class FDAPromptTests: XCTestCase {

    // MARK: - shouldOfferFullDiskAccess

    func test_offers_when_fda_missing_and_folders_denied() {
        XCTAssertTrue(
            ScanViewModel.shouldOfferFullDiskAccess(
                deniedCount: 241,
                hasFullDiskAccess: false,
                suppressed: false
            )
        )
    }

    func test_does_not_offer_when_fda_already_granted() {
        XCTAssertFalse(
            ScanViewModel.shouldOfferFullDiskAccess(
                deniedCount: 241,
                hasFullDiskAccess: true,
                suppressed: false
            )
        )
    }

    func test_does_not_offer_when_no_folders_denied() {
        XCTAssertFalse(
            ScanViewModel.shouldOfferFullDiskAccess(
                deniedCount: 0,
                hasFullDiskAccess: false,
                suppressed: false
            )
        )
    }

    func test_does_not_offer_when_suppressed() {
        XCTAssertFalse(
            ScanViewModel.shouldOfferFullDiskAccess(
                deniedCount: 241,
                hasFullDiskAccess: false,
                suppressed: true
            )
        )
    }
}
