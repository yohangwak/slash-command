import Foundation

/// 시스템 설정의 화면을 «이 macOS 가 부르는 이름» 으로 부른다.
///
/// 앱 권한 목록 «Accessibility(손쉬운 사용)» 를 macOS 27 은 «Device Control and Data Access(기기 제어 및 데이터 접근)» 라고 부른다
/// (2026-10-12 macOS 27.0.1 두 대에서 확인) — 예전 이름으로 안내하면 열어 준 화면의 제목과 다르다.
/// 그래서 시스템 설정의 번역표에서 그대로 읽고, 읽지 못하면 우리 번역의 «Accessibility» 를 쓴다.
public enum SettingsNames {
    /// 시스템 설정 → Privacy & Security 의 그 앱 권한 목록 이름.
    public static let accessibility: String = system(key: "ACCESSIBILITY") ?? loc("Accessibility")

    static let privacyExtension = "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex"

    /// 시스템 설정의 «개인정보 보호 및 보안» 번역표에서 그 키의 글. 없으면 nil.
    static func system(key: String, bundlePath: String = privacyExtension) -> String? {
        guard let bundle = Bundle(path: bundlePath) else { return nil }
        let missing = "\u{1}"
        let value = bundle.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing || value.isEmpty || value == key ? nil : value
    }
}
