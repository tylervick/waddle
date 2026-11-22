import Foundation
import XCTest

/// DIAGNOSTIC for issue 439, not for merge. Sorts just before
/// ImportNoticeBannerTests and leaves busy threads running into it, so the
/// test process's first Metal pipeline build is starved of CPU.
final class ImportNoticeBannerBurnTests: XCTestCase {
    func testStarveTheFirstPipelineBuild() {
        for _ in 0..<12 {
            let thread = Thread {
                let end = Date().addingTimeInterval(45)
                var x = 1.0
                while Date() < end { x = sin(x) + 1 }
                if x == 42 { print(x) }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        NSLog("ImportNoticeBannerBurnTests: 12 busy threads for 45 s")
    }
}
