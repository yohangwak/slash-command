import XCTest
@testable import SlashCommandCore

/// Every language Orca 1.4.257 ships: the close button's label `Close tab {{value0}}` as each catalog translates it
/// (`app.asar.unpacked/out/renderer/assets/<lang>-*.json`, key `auto.components.tab.bar.SortableTab.6df69d9388`, read 2026-11-13).
final class OrcaLanguagesTests: XCTestCase {
    private let templates = [
        "en": "Close tab {{value0}}", "de": "Tab {{value0}} schließen", "es": "Cerrar pestaña {{value0}}",
        "fr": "Fermer l'onglet {{value0}}", "ja": "タブ {{value0}} を閉じる", "ko": "탭 닫기 {{value0}}",
        "pt": "Fechar aba {{value0}}", "ru": "Закрыть вкладку {{value0}}", "tr": "{{value0}} sekmesini kapat",
        "zh-Hant": "關閉分頁 {{value0}}", "zh": "关闭选项卡 {{value0}}",
    ]
    private let titles = ["Terminal 1", "## HEAD (no branch) cd13acc WKBL", "weekly-review(이어서)", "日本語のタイトル",
                          "Привет мир", "Tab", "kapat", "l'onglet", "1"]

    func testReadsEveryTitleInEveryLanguage() {
        for (language, template) in templates {
            for title in titles {
                let label = template.replacingOccurrences(of: "{{value0}}", with: title)
                let tab = OrcaView.tab(classes: ["bg-tab-active", "text-tab-active-foreground"], texts: [title],
                                       buttonLabels: ["Collapse pane", label], label: "")
                XCTAssertEqual(tab, .init(title: title, truncated: false, active: true), "\(language): \(title)")
                // An agent's title is shown without its leading status mark but named with it.
                let marked = template.replacingOccurrences(of: "{{value0}}", with: "✳ \(title)")
                XCTAssertEqual(OrcaView.tab(classes: ["bg-tab-inactive"], texts: [title], buttonLabels: [marked])?.title, title, "\(language): ✳ \(title)")
            }
            // A close button for another tab does not name this one.
            let other = template.replacingOccurrences(of: "{{value0}}", with: "Terminal 12")
            XCTAssertNil(OrcaView.tab(classes: ["bg-tab-inactive"], texts: ["Terminal 1"], buttonLabels: [other]), language)
        }
    }
}
