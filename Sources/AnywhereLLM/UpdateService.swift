import AppKit
import CryptoKit
import Foundation
import LLMCore

/// 인스톨러 없는 자체 업데이터. GitHub Releases 확인 → self-contained .app zip 다운로드
/// → SHA256 검증 → ditto로 풀고 → 실행 중 앱 번들을 교체·재실행하는 헬퍼 셸 스크립트로 위임.
/// 순수 로직(버전 비교, JSON·체크섬 파싱)은 LLMCore/UpdateCheck. Windows
/// UpdateService.cs와 대칭.
enum UpdateService {
    private static let repoOwner = "scian0204"
    private static let repoName = "AnywhereLLM"
    private static let assetSuffix = "-macos.zip"
    private static let checksumAsset = "SHA256SUMS.txt"

    static var releasesPageURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
    }

    /// Info.plist의 표시 버전(M.m.p) — 릴리즈 태그(v 접두 제거 후)와 비교.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    enum UpdateError: LocalizedError {
        case missingAsset, checksumMismatch, noAppInZip, unzipFailed
        var errorDescription: String? {
            switch self {
            case .missingAsset: return "release is missing the macos zip or SHA256SUMS.txt"
            case .checksumMismatch: return "checksum mismatch"
            case .noAppInZip: return "no .app inside the downloaded zip"
            case .unzipFailed: return "failed to unzip the update"
            }
        }
    }

    private static var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        return URLSession(configuration: cfg)
    }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("AnywhereLLM-Updater", forHTTPHeaderField: "User-Agent") // GitHub API는 UA 없으면 403
        return r
    }

    /// 새 릴리즈, 최신이거나 실패면 nil (자동 확인은 네트워크 오류를 노출하지 않는다).
    static func check() async -> ReleaseInfo? {
        do {
            let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
            let (data, _) = try await session.data(for: request(url))
            guard let rel = parseLatestRelease(data) else { return nil }
            return isNewer(current: currentVersion, latest: rel.tag) ? rel : nil
        } catch {
            return nil
        }
    }

    /// macos zip 다운로드 → SHA256SUMS.txt와 대조 → ditto로 해제 → 헬퍼 스크립트로 번들
    /// 교체+재실행. 네트워크·검증 실패 시 throw(교체 안 함). 번들 부모가 쓰기 불가면
    /// 릴리즈 페이지를 열고 false. true면 호출측이 앱을 종료해 헬퍼가 진행하게 한다.
    static func downloadAndApply(_ release: ReleaseInfo) async throws -> Bool {
        guard let asset = pickAsset(release.assets, suffix: assetSuffix),
              let sums = pickAsset(release.assets, suffix: checksumAsset),
              let assetURL = URL(string: asset.downloadURL),
              let sumsURL = URL(string: sums.downloadURL) else {
            throw UpdateError.missingAsset
        }

        let bundlePath = Bundle.main.bundlePath
        let bundleParent = (bundlePath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: bundleParent) else {
            NSWorkspace.shared.open(releasesPageURL)   // /Applications 등 root 소유 → 수동 안내
            return false
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("anywherellm-update-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let zipURL = work.appendingPathComponent(asset.name)
        try await download(assetURL, to: zipURL)

        let (sumsData, _) = try await session.data(for: request(sumsURL))
        let sumsText = String(data: sumsData, encoding: .utf8) ?? ""
        let expected = parseChecksums(sumsText)[asset.name]
        let actual = try sha256Hex(zipURL)
        guard let expected, expected.caseInsensitiveCompare(actual) == .orderedSame else {
            throw UpdateError.checksumMismatch
        }

        let extractDir = work.appendingPathComponent("extracted")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try unzip(zipURL, to: extractDir)

        guard let newApp = firstAppBundle(in: extractDir) else { throw UpdateError.noAppInZip }

        launchSwapAndRelaunch(oldApp: bundlePath, newApp: newApp.path)
        return true
    }

    // MARK: - internals

    private static func download(_ url: URL, to dest: URL) async throws {
        let (tmp, response) = try await session.download(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    private static func sha256Hex(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)   // 업데이트 zip은 수십 MB — 한 번에 읽어도 무방
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func unzip(_ zip: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError.unzipFailed }
    }

    private static func firstAppBundle(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        // ditto가 한 단계 폴더 아래에 풀 수도 있어 한 레벨만 더 탐색.
        for sub in items where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let nested = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) { return nested }
        }
        return nil
    }

    /// 분리 실행되는 셸 스크립트: 우리 PID가 죽을 때까지 대기 → 구 번들 제거 → 신 번들
    /// 복사 → quarantine 제거 → 재실행. (URLSession 다운로드엔 quarantine가 안 붙지만 방어적)
    private static func launchSwapAndRelaunch(oldApp: String, newApp: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(oldApp)"
        /usr/bin/ditto "\(newApp)" "\(oldApp)"
        /usr/bin/xattr -dr com.apple.quarantine "\(oldApp)" 2>/dev/null
        /usr/bin/open "\(oldApp)"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anywherellm-update-\(pid).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path]
        try? p.run()   // 대기하지 않음 — 우리보다 오래 산다
    }
}
