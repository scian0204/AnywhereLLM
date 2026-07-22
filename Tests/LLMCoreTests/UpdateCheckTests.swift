import Testing
import Foundation
@testable import LLMCore

/// Windows AnywhereLLM.Core.Tests/Program.cs의 UpdateCheck 케이스와 동일.
@Suite struct UpdateCheckTests {
    @Test func newerCases() {
        #expect(isNewer(current: "0.4.1", latest: "0.5.0"))
        #expect(isNewer(current: "0.4.1", latest: "0.4.10"))
        #expect(isNewer(current: "0.4", latest: "0.4.1"))
        #expect(isNewer(current: "0.4.1", latest: "v0.5.0"))
    }

    @Test func notNewerCases() {
        #expect(!isNewer(current: "0.5.0", latest: "0.5.0"))
        #expect(!isNewer(current: "0.5.0", latest: "0.4.9"))
        #expect(!isNewer(current: "0.4.1", latest: "garbage"))
    }

    private static let releaseJSON = """
    {"tag_name":"v0.5.0","assets":[
    {"name":"AnywhereLLM-0.5.0-macos.zip","browser_download_url":"https://x/mac.zip","size":123},
    {"name":"AnywhereLLM-0.5.0-win-x64.zip","browser_download_url":"https://x/win.zip","size":456},
    {"name":"SHA256SUMS.txt","browser_download_url":"https://x/sums","size":10}]}
    """.data(using: .utf8)!

    @Test func parsesRelease() {
        let rel = parseLatestRelease(Self.releaseJSON)
        #expect(rel?.tag == "v0.5.0")
        #expect(rel?.assets.count == 3)
    }

    @Test func picksMacAssetNotWin() {
        let rel = parseLatestRelease(Self.releaseJSON)!
        #expect(pickAsset(rel.assets, suffix: "-macos.zip")?.name == "AnywhereLLM-0.5.0-macos.zip")
        #expect(pickAsset(rel.assets, suffix: "-macos.zip")?.downloadURL == "https://x/mac.zip")
        #expect(pickAsset(rel.assets, suffix: "-no-such.zip") == nil)
    }

    @Test func rejectsMalformedRelease() {
        #expect(parseLatestRelease(Data("{not json".utf8)) == nil)
        #expect(parseLatestRelease(Data("{}".utf8)) == nil)
    }

    @Test func parsesChecksums() {
        let sums = parseChecksums(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  AnywhereLLM-0.5.0-macos.zip\n" +
            "# a comment line\n" +
            "0000000000000000000000000000000000000000000000000000000000000000 *AnywhereLLM-0.5.0-x64.msi\n")
        #expect(sums["AnywhereLLM-0.5.0-macos.zip"]
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(sums["AnywhereLLM-0.5.0-x64.msi"]
                == "0000000000000000000000000000000000000000000000000000000000000000")
        #expect(sums.count == 2)
    }
}
