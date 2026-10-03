import SwiftUI
import AppKit
import SwiftTerm

/// Номер волны (как WaveMarker на винде) — видно в «О QTerm».
enum QTermBuild {
    static let wave = 21
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
    /// Время сборки бинаря — проверка «запущен свежий».
    static var binaryDate: String {
        guard let url = Bundle.main.executableURL,
              let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f.string(from: d)
    }
}

/// Тема (канон Windows: dark | light | system). Тёмная = ВСЁ тёмное как
/// было (интерфейс и терминалы), светлая = всё светлое; смешанных нет.
enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: return "Тёмная"
        case .light: return "Светлая"
        case .system: return "Как в системе"
        }
    }
}

/// Шрифт и цвета терминалов (SSH и Mac), живое применение ко всем вкладкам.
enum TerminalLook {
    static let themeKey = "appTheme"
    static let fontNameKey = "termFontName"   // "" — системный моноширинный
    static let fontSizeKey = "termFontSize"
    static let fontSizeDefault = 13.0
    static let fontSizeRange = 8.0...36.0

    static var theme: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .dark
    }

    static var font: NSFont {
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        let size = stored > 0 ? min(max(stored, fontSizeRange.lowerBound), fontSizeRange.upperBound) : fontSizeDefault
        let name = UserDefaults.standard.string(forKey: fontNameKey) ?? ""
        if !name.isEmpty, let f = NSFont(name: name, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Моноширинные семейства для выбора в настройках.
    @MainActor
    static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { fam in
            guard let f = NSFont(name: fam, size: 13) ?? NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: 13)
            else { return false }
            return f.isFixedPitch
        }
    }

    /// Цвета SwiftTerm по умолчанию (как было на SSH-вкладках) — снимаются
    /// с первого свежего SSH-терминала до любых правок.
    private static var pristineFG: NSColor?
    private static var pristineBG: NSColor?

    @MainActor
    static var isDark: Bool {
        switch theme {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    @MainActor
    private static func resolved(_ c: NSColor, dark: Bool) -> NSColor {
        var out = c
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = c.usingColorSpace(.sRGB) ?? c
        }
        return out
    }

    /// Шрифт + цвета одной вкладки. local — вкладка «Mac» (у неё были
    /// системные цвета configureNativeColors).
    @MainActor
    static func style(_ tv: TerminalView, local: Bool) {
        if !local, pristineFG == nil {
            pristineFG = tv.nativeForegroundColor
            pristineBG = tv.nativeBackgroundColor
        }
        let f = font
        if tv.font != f { tv.font = f }
        let fg: NSColor, bg: NSColor
        if isDark {
            if local {
                fg = resolved(.textColor, dark: true)
                bg = resolved(.textBackgroundColor, dark: true)
            } else {
                fg = pristineFG ?? NSColor(white: 0.9, alpha: 1)
                bg = pristineBG ?? .black
            }
        } else {
            fg = resolved(.textColor, dark: false)
            bg = resolved(.textBackgroundColor, dark: false)
        }
        if tv.nativeForegroundColor != fg { tv.nativeForegroundColor = fg }
        if tv.nativeBackgroundColor != bg { tv.nativeBackgroundColor = bg }
    }

    /// Тема интерфейса + перекраска всех живых терминалов.
    @MainActor
    static func apply(_ state: AppState) {
        switch theme {
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .system: NSApplication.shared.appearance = nil
        }
        for tv in state.terminals.values { style(tv, local: false) }
        for tv in state.localTerminals.values { style(tv, local: true) }
    }

    private static var systemObserver: NSObjectProtocol?

    /// «Как в системе»: перекрашиваться при смене темы macOS.
    @MainActor
    static func install(_ state: AppState) {
        apply(state)
        guard systemObserver == nil else { return }
        systemObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak state] _ in
            MainActor.assumeIsolated {
                guard let state, theme == .system else { return }
                // effectiveAppearance обновляется чуть позже нотификации.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated { apply(state) }
                }
            }
        }
    }
}

// MARK: - О приложении

struct AboutView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var info: String {
        """
        QTerm \(QTermBuild.version) (билд \(QTermBuild.build)) · волна \(QTermBuild.wave) · бинарь \(QTermBuild.binaryDate)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Нод: \(state.visibleSessions.count) · ключей: \(state.visibleKeys.count) · сниппетов: \(state.visibleSnippets.count) · команд Git: \(state.visibleGitCommands.count)
        Журнал: \(state.cmdHistory.values.filter { $0.deleted != true }.count) команд
        """
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("QTerm").font(.largeTitle).bold()
            Text("\(QTermBuild.version) · билд \(QTermBuild.build) · волна \(QTermBuild.wave)")
                .foregroundStyle(.secondary)
            Text("SSH-клиент в духе MobaXterm: ноды, вкладки, SFTP, редактор, вейлт с синком между Mac, Windows и Android.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text(info)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
            Text("SwiftUI · SwiftTerm · Citadel/SwiftNIO SSH · CodeEditSourceEditor · SessionVaultKit")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Link("GitHub", destination: URL(string: "https://github.com/Q00000P/QTerm")!)
                Link("Релизы", destination: URL(string: "https://github.com/Q00000P/QTerm/releases")!)
                Spacer()
                Button(copied ? "Скопировано" : "Копировать сведения") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info, forType: .string)
                    copied = true
                }
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
