import Foundation

/// 자체 업데이터의 순수 로직: 버전 비교, GitHub 릴리즈 JSON 파싱, 에셋 선택,
/// 체크섬 파일 파싱. 네트워크·파일 I/O는 여기 없다 — 앱의 UpdateService 담당.
/// Windows AnywhereLLM.Core/UpdateCheck.cs와 동일 동작.

public struct ReleaseAsset: Equatable {
    public let name: String
    public let downloadURL: String
    public let size: Int
    public init(name: String, downloadURL: String, size: Int) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
    }
}

public struct ReleaseInfo: Equatable {
    public let tag: String
    public let assets: [ReleaseAsset]
    public init(tag: String, assets: [ReleaseAsset]) {
        self.tag = tag
        self.assets = assets
    }
}

/// latest가 current보다 엄격히 높은 semver일 때만 true. 선행 "v" 제거. 파싱 불가/
/// 동일/더 낮음이면 false (유일한 다운그레이드·재설치 방지 게이트).
public func isNewer(current: String, latest: String) -> Bool {
    guard let c = versionComponents(current), let l = versionComponents(latest) else { return false }
    let n = max(c.count, l.count)
    for i in 0..<n {
        let cv = i < c.count ? c[i] : 0
        let lv = i < l.count ? l[i] : 0
        if lv != cv { return lv > cv }
    }
    return false // 동일
}

private func versionComponents(_ version: String) -> [Int]? {
    var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
    if v.lowercased().hasPrefix("v") { v.removeFirst() }
    if v.isEmpty { return nil }
    var nums: [Int] = []
    // omittingEmptySubsequences: false — "0..1" 같은 빈 성분은 파싱 실패로 nil (C# Split과 동일).
    for part in v.split(separator: ".", omittingEmptySubsequences: false) {
        guard let num = Int(part) else { return nil }
        nums.append(num)
    }
    return nums
}

/// GitHub /releases/latest 응답 파싱. tag_name 필수; name/browser_download_url 없는
/// 에셋은 건너뜀. JSON 불량/태그 없음이면 nil.
public func parseLatestRelease(_ json: Data) -> ReleaseInfo? {
    guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
          let tag = obj["tag_name"] as? String else { return nil }
    var assets: [ReleaseAsset] = []
    if let arr = obj["assets"] as? [[String: Any]] {
        for a in arr {
            guard let name = a["name"] as? String,
                  let url = a["browser_download_url"] as? String else { continue }
            let size = (a["size"] as? Int) ?? 0
            assets.append(ReleaseAsset(name: name, downloadURL: url, size: size))
        }
    }
    return ReleaseInfo(tag: tag, assets: assets)
}

/// 이름이 플랫폼 접미사로 끝나는 첫 에셋(예: "-macos.zip") — MSI와 다른 플랫폼 zip은
/// 무시. 매치 없으면 nil.
public func pickAsset(_ assets: [ReleaseAsset], suffix: String) -> ReleaseAsset? {
    let s = suffix.lowercased()
    return assets.first { $0.name.lowercased().hasSuffix(s) }
}

/// `<sha256>  <filename>` 체크섬 파일 파싱(sha256sum 형식; "*" 바이너리 마커 허용).
/// 형식 불일치 줄 무시. 해시는 소문자로. name -> hash 반환.
public func parseChecksums(_ text: String) -> [String: String] {
    var map: [String: String] = [:]
    let regex = try! NSRegularExpression(pattern: "^([0-9a-fA-F]{64})\\s+\\*?(.+)$")
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines) // CRLF의 \r 포함 제거
        let range = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: range),
              let hashR = Range(m.range(at: 1), in: line),
              let nameR = Range(m.range(at: 2), in: line) else { continue }
        let name = line[nameR].trimmingCharacters(in: .whitespaces)
        map[name] = line[hashR].lowercased()
    }
    return map
}
