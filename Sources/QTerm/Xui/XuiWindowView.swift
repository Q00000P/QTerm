import SwiftUI
import AppKit

/// Окно «Ноды 3x-ui»: монитор, клиенты × серверы, узлы, ревизия имён, AWG. Порт XuiWindow.xaml.
struct XuiWindowView: View {
    @StateObject private var m = XuiModel()
    @ObservedObject private var center = XuiCenter.shared
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            topBar
            Picker("", selection: $m.seg) {
                ForEach(XuiModel.Seg.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VSplitView {
                ZStack {
                    switch m.seg {
                    case .monitor: monitorView
                    case .clients: clientsView
                    case .nodes: nodesView
                    case .names: namesView
                    case .awg: awgView
                    }
                    if m.noMaster && m.seg != .awg { setupCard }
                }
                .frame(minHeight: 260)
                logView.frame(minHeight: 70, idealHeight: 140)
            }
        }
        .padding(12)
        .frame(minWidth: 900, minHeight: 560)
        .onReceive(timer) { _ in Task { await m.tick() } }
        .onAppear { takeNodeAddRequest() }
        .onChange(of: center.nodeAddRequest?.id) { _, _ in takeNodeAddRequest() }
        .sheet(item: $m.planRequest) { req in PlanSheet(req: req) { ok in m.planRequest = nil; req.done?(ok) } }
        .sheet(item: $m.connectRequest) { req in ConnectSheet(req: req) { r in m.connectRequest = nil; req.done?(r) } }
        .sheet(item: $m.qr) { XuiQRSheet(info: $0) }
        .sheet(isPresented: $m.showPanels, onDismiss: { Task { await m.reloadPanels() } }) {
            PanelsSheet(store: m.store)
        }
        .sheet(item: $m.nodeAdd) { req in
            NodeAddSheet(store: m.store, selection: req.text) { saved, connectId, passwords in
                m.nodeAdd = nil
                XuiCenter.scrubClipboard(passwords)
                if !saved.isEmpty { Task { await m.afterNodeAdded(saved, connectId: connectId) } }
            }
        }
    }

    private func takeNodeAddRequest() {
        guard let r = center.nodeAddRequest else { return }
        center.nodeAddRequest = nil
        m.nodeAdd = r
    }

    // MARK: верх

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Главная:").foregroundStyle(.secondary)
            Picker("", selection: $m.masterId) {
                if m.masters.isEmpty { Text("—").tag("") }
                ForEach(m.masters) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 220)
            Button("Панели и токены…") { m.showPanels = true }
                .help("Адреса панелей и их токены/пароли. Хранятся в вейлте QTerm и едут синком в зашифрованном виде")
            Button("＋ Нода из выделения") { m.nodeAdd = NodeAddRequest(text: XuiCenter.clipboardText()) }
                .help("Итог установщика 3x-ui / AWG: выдели его в терминале (выделение копируется) и нажми. Новая нода или переустановка")
            Button("Обновить") {
                Task {
                    if m.seg == .awg { await m.refreshAwg() } else { await m.refresh() }
                }
            }
                .keyboardShortcut("r", modifiers: .command)
            if m.busy { ProgressView().controlSize(.small) }
            Text(m.status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer()
        }
    }

    // MARK: первая настройка

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Подключи главную панель 3x-ui").font(.title3.bold())
            Text("Главная — панель, куда добавлены узлы (встроенный мультинод 3x-ui v3): с неё клиенты и единая подписка. Токен: Настройки панели → Учётная запись → API-токены. Или «＋ Нода из выделения» — войду по паролю и выпущу токен сам.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Имя (MSK)", text: $m.setupName)
            TextField("Адрес панели — как в браузере (https://домен:порт/путь/)", text: $m.setupUrl)
            SecureField("API-токен", text: $m.setupToken)
            Toggle("Проверять сертификат", isOn: $m.setupVerify)
            HStack {
                Button("Проверить и сохранить") { Task { await m.setupSave() } }.keyboardShortcut(.defaultAction)
                Button("＋ Из выделения / по паролю…") { m.nodeAdd = NodeAddRequest(text: XuiCenter.clipboardText()) }
                Text(m.setupResult).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
    }

    // MARK: монитор

    private var monitorView: some View {
        Table(m.monRows) {
            TableColumn("Сервер") { r in Text(r.name).bold() }.width(min: 120, ideal: 160)
            TableColumn("Статус") { r in Text(r.status).foregroundStyle(r.statusColor) }.width(min: 60, ideal: 80)
            TableColumn("Пинг") { r in Text(r.ping) }.width(min: 40, ideal: 60)
            TableColumn("CPU") { r in Text(r.cpu) }.width(min: 40, ideal: 50)
            TableColumn("RAM") { r in Text(r.ram) }.width(min: 40, ideal: 50)
            TableColumn("Аптайм") { r in Text(r.uptime) }.width(min: 60, ideal: 90)
            TableColumn("Xray") { r in Text(r.xray) }.width(min: 50, ideal: 70)
            TableColumn("Онлайн / клиентов") { r in Text(r.clients) }.width(min: 70, ideal: 110)
            TableColumn("Сеть") { r in Text(r.net) }.width(min: 120, ideal: 190)
            TableColumn("Ошибка") { r in Text(r.error).foregroundStyle(.red).help(r.error) }
        }
    }

    // MARK: клиенты

    private var clientsView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Поиск по имени / ID подписки", text: $m.search).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Синхронизировать…") { Task { await m.clientSync() } }
                    .help("Добавить выделенных (или всех) клиентов на все серверы, где их нет. План с галками")
                Button("＋ Клиент") { Task { await m.clientNew() } }
                Button("Ссылка") { if let c = oneClient() { m.copyLink(c) } }
                Button("QR") { if let c = oneClient() { m.showQR(c) } }
                Button("Вкл / выкл") { Task { await m.toggle(m.selectedClients()) } }
                Button("Удалить") { Task { await m.delete(m.selectedClients()) } }
                Spacer()
                Text("V — VLESS · H — Hysteria · зелёным — сдвоенные").foregroundStyle(.secondary).font(.caption)
            }
            let srv = m.servers
            Table(m.clientRows, selection: $m.clientSel) {
                TableColumn("") { r in Text("●").foregroundStyle(r.dot) }.width(16)
                TableColumn("Клиент") { r in Text(r.email).foregroundStyle(r.merged ? Color.green : Color.primary) }
                    .width(min: 110, ideal: 170)
                TableColumn("Вкл") { r in Text(r.enabled) }.width(36)
                TableColumnForEach(srv) { s in
                    TableColumn(s.title) { r in
                        let cell = s.index < r.cells.count ? r.cells[s.index] : ("—", Color.secondary)
                        Text(cell.0).foregroundStyle(cell.1)
                    }
                    .width(min: 50, ideal: 70)
                }
                TableColumn("Трафик") { r in Text(r.traffic) }.width(min: 80, ideal: 140)
                TableColumn("Срок") { r in Text(r.expiry) }.width(min: 70, ideal: 110)
                TableColumn("ID подписки") { r in Text(r.subId) }.width(min: 80, ideal: 150)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                clientMenu(m.selectedClients(ids))
            } primaryAction: { ids in
                if let c = m.selectedClients(ids).first { m.showQR(c) }
            }
        }
    }

    private func oneClient() -> XClient? {
        let s = m.selectedClients()
        if s.count == 1 { return s[0] }
        XuiDialog.info("Выбери одного клиента")
        return nil
    }

    @ViewBuilder
    private func clientMenu(_ sel: [XClient]) -> some View {
        if !sel.isEmpty {
            Button("Синхронизировать на все серверы…") {
                Task { await m.runSync("Синхронизация клиентов", "\(sel.map(\.email).joined(separator: ", ")) → все серверы",
                                       m.syncItems(sel, nodeFilter: nil)) }
            }
            Menu("Привязать к") {
                ForEach(m.servers) { s in
                    let ibs = m.inbounds.filter { $0.nodeId == s.nodeId && $0.multiUser }
                    if !ibs.isEmpty {
                        Menu(s.title) {
                            Button("все входящие") { Task { await m.bind(sel, ibs.map(\.id), attach: true, s.title) } }
                            Divider()
                            ForEach(ibs) { ib in
                                Button("\(ib.remark)  (\(ib.proto):\(ib.port))") {
                                    Task { await m.bind(sel, [ib.id], attach: true, ib.remark) }
                                }
                            }
                        }
                    }
                }
            }
            Menu("Отвязать от") {
                ForEach(m.servers) { s in
                    let bound = m.inbounds.filter { ib in
                        ib.nodeId == s.nodeId && ib.multiUser && sel.contains { $0.inboundIds.contains(ib.id) }
                    }
                    if !bound.isEmpty {
                        Menu(s.title) {
                            Button("все входящие") { Task { await m.bind(sel, bound.map(\.id), attach: false, s.title) } }
                            Divider()
                            ForEach(bound) { ib in
                                Button("\(ib.remark)  (\(ib.proto):\(ib.port))") {
                                    Task { await m.bind(sel, [ib.id], attach: false, ib.remark) }
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            if sel.count == 1 {
                Button("Скопировать ссылку подписки") { m.copyLink(sel[0]) }
                if m.linkOf(sel[0], clash: true) != nil {
                    Button("Скопировать ссылку Clash / Mihomo") { m.copyLink(sel[0], clash: true) }
                }
                Button("QR-код") { m.showQR(sel[0]) }
                Divider()
                Button("Переименовать…") { Task { await m.rename(sel[0]) } }
                Button("Новый ID подписки…") { Task { await m.regenSubId(sel[0]) } }
            }
            Button(sel.allSatisfy(\.enable) ? "Выключить" : "Включить") { Task { await m.toggle(sel) } }
            Button("Удалить…") { Task { await m.delete(sel) } }
        }
    }

    // MARK: узлы

    private var nodesView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button("＋ Подключить ноду…") { Task { await m.nodeConnect() } }
                    .help("Бэкапы → чистка дублей на ноде → регистрация на главной (токен node-sync) → единые имена → привязка")
                Button("Ревизия ноды") { Task { await m.nodeRevise() } }
                Button("Выровнять клиентов") { Task { await m.nodeSync() } }
                    .help("Добавить на выбранный узел всех клиентов главной, которых на нём нет. План с галками")
                Button("Вкл / выкл") { Task { await m.nodeToggle() } }
                Button("Проверить связь") { Task { await m.nodeProbe() } }
                Button("Токен ноды…") { Task { await m.nodeToken() } }
                Spacer()
            }
            Table(m.nodeRows, selection: $m.nodeSel) {
                TableColumn("Узел") { r in Text(r.name).bold() }.width(min: 80, ideal: 120)
                TableColumn("Адрес") { r in Text(r.address) }.width(min: 160, ideal: 260)
                TableColumn("Статус") { r in Text(r.status).foregroundStyle(r.statusColor) }.width(min: 60, ideal: 80)
                TableColumn("Вкл") { r in Text(r.src.enable ? "да" : "нет") }.width(36)
                TableColumn("Входящих") { r in Text("\(r.src.inboundCount)") }.width(60)
                TableColumn("Клиентов") { r in Text("\(r.src.clientCount)") }.width(60)
                TableColumn("Токен в QTerm") { r in Text(r.saved == nil ? "—" : "есть") }.width(90)
                TableColumn("Версия") { r in Text(r.src.panelVersion) }.width(min: 50, ideal: 70)
                TableColumn("Ошибка") { r in Text(r.src.lastError).foregroundStyle(.red).help(r.src.lastError) }
            }
            .contextMenu(forSelectionType: Int.self) { _ in
                Button("Ревизия ноды") { Task { await m.nodeRevise() } }
                Button("Выровнять клиентов") { Task { await m.nodeSync() } }
                Button("Токен ноды…") { Task { await m.nodeToken() } }
            } primaryAction: { _ in Task { await m.nodeRevise() } }
        }
    }

    // MARK: ревизия имён

    private var namesView: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Список имён: по строке «ИМЯ» или «СИНОНИМ = ИМЯ», # — комментарий. Индекс ставится сам: PC — VLESS, PC-HYS — Hysteria, PC-SYNC — оба.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $m.namesText).font(.system(.body, design: .monospaced))
                HStack {
                    Button("Сохранить") { m.namesSave() }
                    Button("По умолчанию") { m.namesDefault() }
                }
            }
            .frame(minWidth: 220, idealWidth: 280)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Переезд на SYNC…") { Task { await m.migrate() } }
                        .help("Записи одного устройства → одна NAME-SYNC на всех входящих VLESS и Hysteria. План с галками")
                    Button("Проанализировать…") { Task { await m.analyze() } }
                        .help("Склейка дублей к списку имён на главной и на нодах с сохранённым токеном. План с галками")
                    Spacer()
                }
                ScrollView {
                    Text(m.planText.isEmpty ? "Здесь будет итог последней ревизии." : m.planText)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minWidth: 360)
            .padding(.leading, 8)
        }
    }

    // MARK: AWG

    private var awgView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Picker("", selection: $m.awgPick) {
                    Text("Все AWG-ноды").tag("")
                    ForEach(m.awgPanels) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 180)
                TextField("Поиск по имени и адресу", text: $m.awgSearch).textFieldStyle(.roundedBorder).frame(width: 170)
                Button("＋ Клиент") { Task { await m.awgNew() } }
                Button("Конфиг → буфер") { Task { await m.awgCopy() } }
                Button("Сохранить .conf") { Task { await m.awgSave() } }
                Button("QR") { Task { await m.awgQR() } }
                Button("Вкл / выкл") { Task { await m.awgToggle() } }
                Button("Удалить") { Task { await m.awgDelete() } }
                Button("Панели…") { m.showPanels = true }
                Text(m.awgStatus).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer()
            }
            Table(m.awgRows, selection: $m.awgSel) {
                TableColumn("") { r in Text("●").foregroundStyle(r.dot) }.width(16)
                TableColumn("Нода") { r in Text(r.src.panel) }.width(min: 60, ideal: 100)
                TableColumn("Клиент") { r in Text(r.src.name).bold() }.width(min: 90, ideal: 150)
                TableColumn("Интерфейс") { r in Text(r.iface) }.width(min: 80, ideal: 120)
                TableColumn("Адрес") { r in Text(r.src.address) }.width(min: 80, ideal: 110)
                TableColumn("Вкл") { r in Text(r.src.enabled ? "да" : "нет") }.width(36)
                TableColumn("Рукопожатие") { r in Text(r.handshake) }.width(min: 80, ideal: 110)
                TableColumn("Трафик ↓/↑") { r in Text(r.traffic) }.width(min: 100, ideal: 150)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let c = m.awgSelected(ids).first {
                    Button("QR") { Task { await m.awgQR(c) } }
                    Button("Конфиг → буфер") { m.awgSel = ids; Task { await m.awgCopy() } }
                }
                if !ids.isEmpty {
                    Button("Сохранить .conf") { m.awgSel = ids; Task { await m.awgSave() } }
                    Button("Вкл / выкл") { m.awgSel = ids; Task { await m.awgToggle() } }
                    Button("Удалить…") { m.awgSel = ids; Task { await m.awgDelete() } }
                }
            } primaryAction: { ids in
                if let c = m.awgSelected(ids).first { Task { await m.awgQR(c) } }
            }
        }
    }

    // MARK: лог

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(m.logLines) { l in
                        Text(l.text).foregroundStyle(l.color).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).id(l.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .onChange(of: m.logLines.count) { _, _ in
                if let last = m.logLines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - План с галками

private struct PlanCheck: View {
    @ObservedObject var item: PlanItem
    let force: Bool
    var body: some View {
        Toggle("", isOn: $item.apply).labelsHidden().disabled(!item.selectable || force)
    }
}

private struct PlanResult: View {
    @ObservedObject var item: PlanItem
    var body: some View {
        if item.editable {
            TextField("", text: $item.result).textFieldStyle(.roundedBorder)
                .foregroundStyle(item.merged ? Color.green : Color.primary)
        } else {
            Text(item.result).foregroundStyle(item.merged ? Color.green : Color.primary).textSelection(.enabled)
        }
    }
}

struct PlanSheet: View {
    let req: PlanRequest
    let finish: (Bool) -> Void
    @State private var filter = ""
    @State private var tick = 0

    private var visible: [PlanItem] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        if f.isEmpty { return req.items }
        return req.items.filter {
            $0.result.localizedCaseInsensitiveContains(f) || $0.from.localizedCaseInsensitiveContains(f) ||
                $0.scope.localizedCaseInsensitiveContains(f) || $0.note.localizedCaseInsensitiveContains(f)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(req.title).font(.title3.bold())
            Text(req.summary).textSelection(.enabled)
            Text(req.note).foregroundStyle(.secondary).font(.caption).textSelection(.enabled)
            Text("Галка — сделать. Без галки строка пропускается. Имя у склеек можно поправить прямо в таблице; зелёным — уже сдвоенные (VLESS + Hysteria).")
                .foregroundStyle(.secondary).font(.caption)
            HStack {
                TextField("Фильтр", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Отметить видимые") { for i in visible where i.selectable { i.apply = true }; tick += 1 }
                Button("Снять видимые") { for i in visible where i.selectable && !req.forceApply { i.apply = false }; tick += 1 }
                Button("Копировать план") { XuiDialog.copy(req.items.map(\.asText).joined(separator: "\n")) }
                Spacer()
                Text("строк: \(req.items.count)").foregroundStyle(.secondary)
            }
            Table(visible) {
                TableColumn("") { i in PlanCheck(item: i, force: req.forceApply && i.kind != "attach") }.width(24)
                TableColumn("Где") { i in Text(i.scope) }.width(min: 50, ideal: 80)
                TableColumn("Что") { i in Text(i.kindText).foregroundStyle(i.kindColor) }.width(min: 100, ideal: 170)
                TableColumn(req.resultHeader) { i in PlanResult(item: i) }.width(min: 120, ideal: 180)
                TableColumn(req.fromHeader) { i in Text(i.from).textSelection(.enabled).help(i.from) }.width(min: 120, ideal: 220)
                TableColumn("Примечание") { i in Text(i.note).foregroundStyle(.secondary).help(i.note) }
            }
            .id(tick)
            HStack {
                Spacer()
                Button("Отмена") { finish(false) }.keyboardShortcut(.cancelAction)
                Button("Выполнить отмеченное") { finish(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 980, idealWidth: 1180, minHeight: 520, idealHeight: 700)
    }
}

// MARK: - Подключение ноды / токен

struct ConnectSheet: View {
    let req: ConnectRequest
    let finish: (ConnectResult?) -> Void
    @State private var url = ""
    @State private var token = ""
    @State private var name = ""
    @State private var verify = true
    @State private var attachOthers = false
    @State private var saveToken = true
    @State private var picked = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(req.tokenOnly ? "Токен ноды \(req.name)" : "Подключить ноду к главной").font(.title3.bold())
            if !req.saved.isEmpty && !req.tokenOnly {
                Picker("Сохранённая", selection: $picked) {
                    Text("—").tag("")
                    ForEach(req.saved) { Text($0.name).tag($0.id) }
                }
                .onChange(of: picked) { _, id in
                    if let p = req.saved.first(where: { $0.id == id }) {
                        url = p.url; token = p.token; name = p.name; verify = p.verifyTls
                    }
                }
            }
            TextField("Адрес панели ноды — как в браузере", text: $url)
            SecureField("API-токен ноды (админский: нужен для бэкапа и выпуска node-sync)", text: $token)
            if !req.tokenOnly {
                TextField("Имя узла на главной (пусто — по домену)", text: $name)
                Toggle("Привязать к ноде всех остальных клиентов главной", isOn: $attachOthers)
                Toggle("Сохранить токен в QTerm (для ревизии)", isOn: $saveToken)
            }
            Toggle("Проверять сертификат", isOn: $verify)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Отмена") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button(req.tokenOnly ? "Проверить и сохранить" : "Далее — план") {
                    if PanelURL.tryParse(url) == nil { error = "не разобрал адрес"; return }
                    if token.trimmingCharacters(in: .whitespaces).isEmpty { error = "Нужен API-токен ноды"; return }
                    finish(ConnectResult(url: url.trimmingCharacters(in: .whitespaces), token: token.trimmingCharacters(in: .whitespaces),
                                         verifyTls: verify, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name,
                                         attachOthers: attachOthers, saveToken: req.tokenOnly || saveToken))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 520)
        .onAppear { url = req.url; name = req.name }
    }
}

// MARK: - Панели и токены

struct PanelsSheet: View {
    let store: XuiStore
    @Environment(\.dismiss) private var dismiss
    @State private var panels: [XuiPanel] = []
    @State private var sel: String?
    @State private var cur: XuiPanel?
    @State private var name = ""
    @State private var role = "node"
    @State private var url = ""
    @State private var login = ""
    @State private var secret = ""
    @State private var verify = true
    @State private var result = ""
    @State private var nodeAdd: NodeAddRequest?

    private let roles = [("master", "3x-ui · главная"), ("node", "3x-ui · нода"),
                         ("awg", "AWG-панель (awg-panel)"), ("awg1", "AWG-панель старая (amnezia-wg-easy, только пароль)")]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                List(panels, selection: $sel) { p in
                    VStack(alignment: .leading) {
                        Text(p.name).bold()
                        Text(p.roleText).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(p.id)
                }
                .frame(width: 240)
                Button("＋ Новая панель") { sel = nil; show(nil) }.frame(maxWidth: .infinity)
                Button("＋ Из выделения / по паролю…") { nodeAdd = NodeAddRequest(text: XuiCenter.clipboardText()) }
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("3x-ui главная — панель, куда добавлены узлы: с неё клиенты и подписки. 3x-ui нода — для ревизии и подключения. AWG-панель — awg-panel (клиенты, конфиги, QR); старая — amnezia-wg-easy с одним паролем. «Проверить» сам определит вид AWG-панели.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        TextField("Имя", text: $name)
                        Picker("Роль", selection: $role) { ForEach(roles, id: \.0) { Text($0.1).tag($0.0) } }
                        TextField("Адрес панели — как в браузере (https://домен:порт/путь/)", text: $url)
                        if role == "awg" { TextField("Логин админа awg-panel (2FA должна быть выключена)", text: $login) }
                        SecureField(secretCaption, text: $secret)
                        Toggle("Проверять сертификат", isOn: $verify)
                        Text(result).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Удалить") { deletePanel() }.disabled(cur == nil)
                    Spacer()
                    Button("Проверить") { Task { await test() } }
                    Button("Сохранить") { save() }.keyboardShortcut(.defaultAction)
                    Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { reload(nil) }
        .onChange(of: sel) { _, id in show(panels.first { $0.id == id }) }
        .sheet(item: $nodeAdd) { req in
            NodeAddSheet(store: store, selection: req.text) { saved, _, passwords in
                nodeAdd = nil
                XuiCenter.scrubClipboard(passwords)
                reload(saved.last?.id)
            }
        }
    }

    private var secretCaption: String {
        switch role {
        case "awg": return "Пароль админа awg-panel. Пусто — оставить сохранённый"
        case "awg1": return "Пароль панели (Password из итога установки). Пусто — оставить сохранённый"
        default: return "API-токен (Настройки панели → Учётная запись → API-токены). Пусто — оставить сохранённый"
        }
    }

    private func reload(_ select: String?) {
        panels = store.panels()
        sel = select ?? panels.first?.id
        show(panels.first { $0.id == sel })
    }

    private func show(_ p: XuiPanel?) {
        cur = p
        name = p?.name ?? ""
        role = p?.role ?? (panels.contains(where: \.isMaster) ? "node" : "master")
        url = p?.url ?? ""
        login = p?.login ?? ""
        secret = ""
        verify = p?.verifyTls ?? true
        result = p == nil ? "Новая панель" : (p!.token.isEmpty ? "Не задано" : (p!.isAwg ? "Пароль сохранён" : "Токен сохранён"))
    }

    private func fromForm() -> XuiPanel? {
        guard PanelURL.tryParse(url) != nil else { result = "✗ не разобрал адрес"; return nil }
        var token = secret.trimmingCharacters(in: .whitespaces)
        if token.isEmpty { token = cur?.token ?? "" }
        if token.isEmpty { result = role.hasPrefix("awg") ? "✗ Нужен пароль" : "✗ Нужен API-токен"; return nil }
        if role == "awg" && login.trimmingCharacters(in: .whitespaces).isEmpty { result = "✗ Нужен логин"; return nil }
        var p = cur ?? XuiPanel()
        p.name = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? String((PanelURL.tryParse(url)?.host ?? "").split(separator: ".").first ?? "").uppercased()
            : name.trimmingCharacters(in: .whitespaces)
        p.role = role
        p.login = role == "awg" ? login.trimmingCharacters(in: .whitespaces) : (role == "awg1" ? "" : p.login)
        p.url = url.trimmingCharacters(in: .whitespaces)
        p.token = token
        p.verifyTls = verify
        return p
    }

    private func test() async {
        guard var p = fromForm() else { return }
        result = "проверяю…"
        do {
            if p.isAwg {
                result = try await AwgProbe.test(&p)
                role = p.role   // вид AWG-панели определился сам
                return
            }
            let api = try XuiAPI.forPanel(p)
            let st = try await api.status()
            var nodes = ""
            if p.isMaster {
                let n = try await api.nodes().count
                nodes = ", узлов: \(n)"
            }
            result = "✓ отвечает, 3x-ui \(J.str(st, "panelVersion"))\(nodes)"
        } catch { result = "✗ " + error.localizedDescription }
    }

    private func save() {
        guard let p = fromForm() else { return }
        store.save(p)
        reload(p.id)
        result = "✓ сохранено (вейлт; синком — в зашифрованном виде)"
    }

    private func deletePanel() {
        guard let c = cur else { return }
        guard XuiDialog.confirm("Удалить «\(c.name)» из QTerm? На самой панели ничего не меняется.", title: "Панели", yes: "Удалить") else { return }
        store.delete(c.id)
        reload(nil)
    }
}
