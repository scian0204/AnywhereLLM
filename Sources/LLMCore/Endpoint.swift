import Foundation

/// Base URL 문자열과 API 경로를 이중 슬래시 없이 합친다.
/// 사용자가 설정에 입력한 값이라 끝 슬래시/공백이 섞여 들어올 수 있다.
public func joinEndpoint(base: String, path: String) -> String {
    var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while b.hasSuffix("/") { b.removeLast() }
    let p = path.hasPrefix("/") ? path : "/" + path
    return b + p
}
