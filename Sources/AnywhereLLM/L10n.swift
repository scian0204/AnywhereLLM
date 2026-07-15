import Foundation

/// Localizable.strings 조회 (SPM 리소스 번들 — en/ko). 시스템 언어 매칭·폴백은
/// Foundation이 처리하고, 미지원 언어는 defaultLocalization(en)으로 떨어진다.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

/// 포맷 인자 버전 — .strings의 %@/%d 자리에 채운다.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: .module, comment: ""), arguments: args)
}
