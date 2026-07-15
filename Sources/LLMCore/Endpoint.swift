import Foundation

/// Base URL 문자열과 API 경로를 이중 슬래시 없이 합친다.
/// 사용자가 설정에 입력한 값이라 끝 슬래시/공백이 섞여 들어올 수 있다.
public func joinEndpoint(base: String, path: String) -> String {
    var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while b.hasSuffix("/") { b.removeLast() }
    let p = path.hasPrefix("/") ? path : "/" + path
    return b + p
}

/// Base URL 문자열에서 scheme://host[:port] origin만 추출 (경로 제거). 실패 시 nil.
/// Ollama 네이티브 API(/api/*)는 /v1 경로 없이 origin에 붙는다.
public func endpointOrigin(_ base: String) -> String? {
    guard let url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme, let host = url.host else { return nil }
    // url.host는 IPv6 리터럴의 대괄호를 벗겨 반환한다("::1") — 재부착하지 않으면
    // "http://::1:11434"처럼 포트와 뒤엉킨 잘못된 origin이 나온다.
    let bracketed = host.contains(":") ? "[\(host)]" : host
    let port = url.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(bracketed)\(port)"
}
