import Foundation
import Security

/// Keychain-backed storage for the LLM API key.
/// Stateless (only static funcs over the Security framework), so it's trivially Sendable-safe.
enum KeychainStore {
    static let service = "kr.scian0204.AnywhereLLM"
    static let account = "apiKey"

    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    static func set(_ value: String) -> Bool {
        // 빈 값 = 항목 삭제. 로컬 서버(Ollama 등)는 키가 없다 — 항목이 남아 있으면
        // 읽을 때마다 키체인 ACL 암호 프롬프트가 뜰 수 있으니 아예 없앤다.
        guard !value.isEmpty else { return delete() }

        // SecItemUpdate는 기존 항목의 ACL(소유 앱 서명)을 그대로 보존한다 — 예전
        // 서명(ad-hoc 등)으로 만든 항목이면 갱신해도 암호 프롬프트가 계속된다.
        // 삭제 후 재추가로 현재 바이너리 소유의 새 ACL을 받는다.
        // 단, add가 실패하면(키체인 잠김/일시 오류) 방금 지운 키가 통째로 사라진다 —
        // 실패 시 이전 값을 되살리고, OSStatus를 남긴다(키 자체는 절대 로그 금지).
        let previous = get()
        delete()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("AnywhereLLM Keychain: SecItemAdd failed (OSStatus %d) — restoring previous key", status)
            if let previous {
                let restore: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecValueData as String: Data(previous.utf8),
                ]
                SecItemAdd(restore as CFDictionary, nil)
            }
            return false
        }
        return true
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
