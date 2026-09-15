import Foundation
import Testing
@testable import VPSQuotaCore

@Suite("应用元信息")
struct AppInfoTests {

    @Test("默认回退版本号与运行时版本号有效")
    func versionIsValid() {
        #expect(!AppInfo.fallbackVersion.isEmpty)
        #expect(!AppInfo.version.isEmpty)
        let parts = AppInfo.version.split(separator: ".")
        #expect(parts.count >= 2)
    }

    @Test("Releases 与 Project URL 有效")
    func urlsAreValid() {
        #expect(AppInfo.projectURL.scheme == "https")
        #expect(AppInfo.projectURL.host == "github.com")
        #expect(AppInfo.releasesURL.scheme == "https")
        #expect(AppInfo.releasesURL.absoluteString.hasSuffix("/releases"))
    }
}
