import Foundation

/// Обмен между QTerm.app и отдельным приложением QTermEditor.app.
///
/// Транспорт нарочно простой и без сокетов: сообщение пишется JSON-файлом в
/// общую папку, а адресату шлётся distributed notification с именем файла.
/// Так нет ни сервера, ни лимитов на размер payload (файлы до 2 МБ), а
/// доставка переживает старт приложения-получателя (папка = очередь).
public enum EditorIPC {

    // MARK: Каналы

    /// Хост → редактор.
    public static let toEditor = Notification.Name("com.q00000p.qterm.ipc.toEditor")
    /// Редактор → хост.
    public static let toHost = Notification.Name("com.q00000p.qterm.ipc.toHost")

    public static let editorBundleID = "com.q00000p.qterm.editor"

    // MARK: Сообщения

    public enum Kind: String, Codable {
        case open        // хост: открыть файл (или обновить содержимое)
        case saved       // хост: результат заливки
        case ping        // хост: «я жив» (редактор проверяет связь)
        case save        // редактор: залить текст на ноду
        case closed      // редактор: вкладка закрыта
        case ready       // редактор: запустился, готов принимать
    }

    public struct Message: Codable {
        public var kind: Kind
        public var docID: String
        public var sessionID: String?
        public var nodeName: String?
        public var remotePath: String?
        public var text: String?
        public var ok: Bool?
        public var error: String?

        public init(
            kind: Kind, docID: String = "",
            sessionID: String? = nil, nodeName: String? = nil,
            remotePath: String? = nil, text: String? = nil,
            ok: Bool? = nil, error: String? = nil
        ) {
            self.kind = kind
            self.docID = docID
            self.sessionID = sessionID
            self.nodeName = nodeName
            self.remotePath = remotePath
            self.text = text
            self.ok = ok
            self.error = error
        }
    }

    // MARK: Папка обмена

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QTerm/ipc", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: Отправка и приём

    public static func send(_ message: Message, to channel: Notification.Name) {
        let url = directory.appendingPathComponent("\(UUID().uuidString).json")
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? data.write(to: url, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(
            channel,
            object: url.lastPathComponent,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Подписка на канал. Файл сообщения удаляется после разбора.
    /// Возвращает токен наблюдателя (держать, пока нужен приём).
    public static func listen(
        _ channel: Notification.Name,
        handler: @escaping (Message) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: channel, object: nil, queue: .main
        ) { note in
            guard let name = note.object as? String else { return }
            let url = directory.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let message = try? JSONDecoder().decode(Message.self, from: data)
            else { return }
            handler(message)
        }
    }

    /// Подобрать сообщения, пришедшие до старта (получатель запускался).
    public static func drainPending(handler: @escaping (Message) -> Void) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url),
                  let message = try? JSONDecoder().decode(Message.self, from: data)
            else { continue }
            try? fm.removeItem(at: url)
            handler(message)
        }
    }

    /// Уборка старых файлов (на случай, если получатель не поднялся).
    public static func sweep(olderThan seconds: TimeInterval = 3600) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        for url in files {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
