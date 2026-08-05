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

    // MARK: - "Access granted!" must reflect an observed grant, not a probe

    // The dead end this guards against: the readability probe claims access
    // while the scan is still being denied hundreds of folders, so opening the
    // sheet from the warning banner landed on a congratulations screen whose
    // only action was a relaunch that changed nothing — and the System
    // Settings button was unreachable.
    func test_granted_state_requires_access_to_have_flipped_while_sheet_open() {
        // Probe already claimed access when the sheet opened: never celebrate.
        XCTAssertFalse(
            FullDiskAccessSheet.showsGrantedState(accessWasMissingOnOpen: false, hasAccessNow: true),
            "a probe that was already true on open is not evidence of a grant"
        )
        // Access was missing and has now appeared: this is the real grant.
        XCTAssertTrue(
            FullDiskAccessSheet.showsGrantedState(accessWasMissingOnOpen: true, hasAccessNow: true)
        )
        // Still missing.
        XCTAssertFalse(
            FullDiskAccessSheet.showsGrantedState(accessWasMissingOnOpen: true, hasAccessNow: false)
        )
        // Before onAppear has recorded the starting state.
        XCTAssertFalse(
            FullDiskAccessSheet.showsGrantedState(accessWasMissingOnOpen: nil, hasAccessNow: true)
        )
    }

    // MARK: - The draggable icon must point at the RUNNING copy

    // macOS grants Full Disk Access to one exact copy of an app. The whole
    // point of dragging the icon instead of using the "+" picker is that the
    // payload cannot be some other build sitting in /Applications, so the
    // dragged URL has to be this bundle and nothing else.
    func test_drag_payload_is_the_running_bundle() {
        XCTAssertEqual(
            FullDiskAccessSheet.runningAppURL(),
            Bundle.main.bundleURL,
            "the drag must carry the running bundle, not a copy found elsewhere"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: FullDiskAccessSheet.runningAppURL().path),
            "the dragged URL must exist on disk or the drop silently does nothing"
        )
        XCTAssertFalse(
            FullDiskAccessSheet.runningAppName().isEmpty,
            "the tile needs a name to label the icon with"
        )
    }
}
