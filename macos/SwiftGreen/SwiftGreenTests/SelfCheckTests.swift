import XCTest
@testable import SwiftGreen

/// The app's built-in Debug self-checks, run by the test suite instead of only at launch.
final class SelfCheckTests: XCTestCase {
    func testSmsClassifier() {
        SmsClassifier.selfCheck()   // assert()s; a failure stops the run
    }
}
