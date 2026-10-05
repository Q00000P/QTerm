import SwiftUI
import AppKit

/// Окно «Каскад»: каскад-серверы слева, справа — обзор, источники нод, кто идёт в каскад, группы, правила, журнал.
/// Порт CascadeWindow.xaml (Windows, волна 38). Отдельное окно — живёт рядом с терминалом и «Нодами 3x-ui».
struct CascadeWindowView: View {
    @StateObject private var m = CascadeModel()
    @EnvironmentObject private var state: AppState
    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VSplitView {
            HSplitView {
                serverList
                    .frame(minWidth: 190, idealWidth: 240, maxWidth: 420)
                VStack(alignment: .leading, spacing: 8) {
                    header
                    Picker("", selection: $m.seg) {
                        ForEach(CascadeModel.Seg.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ZStack {
                        content
                        if let card = m.card { cardView(card) }
                    }
                }
                .padding(.leading, 8)
                .frame(minWidth: 640)
            }
            .frame(minHeight: 380)
            XuiLogView(lines: m.logLines, onClear: { [weak mm = m] in mm?.logLines.removeAll() })
                .frame(minHeight: 70, idealHeight: 150)
        }
        .padding(12)
        .frame(minWidth: 980, minHeight: 620)
        .onReceive(timer) { _ in Task { await m.tick() } }
        .onAppear {
            let st = state
            m.execInSession = { [weak st] id, cmd, t in
                guard let st else { throw XuiError("QTerm закрывается") }
                return try await st.execInSession(id, cmd, timeout: t)
            }
            m.sessionConnected = { [weak st] id in st?.sessionConnected(id) ?? false }
            Task { await m.refresh() }
        }
        .sheet(item: $m.pickRequest) { req in PickSheet(req: req) { v in m.pickRequest = nil; req.done?(v) } }
        .sheet(item: $m.xuiSource) { req in
            XuiSourceSheet(req: req, store: m.store, log: { [weak mm = m] s in mm?.log(s, .ok) }) { s in m.xuiSource = nil; req.finish(s) }
        }
        .sheet(item: $m.wgSource) { req in
            WgSourceSheet(req: req, store: m.store, log: { [weak mm = m] s in mm?.log(s, .ok) }) { r in m.wgSource = nil; req.finish(r) }
        }
        .sheet(item: $m.install) { req in
            InstallSheet(req: req, store: m.store, log: { [weak mm = m] s in mm?.log(s, .ok) }) { r in m.install = nil; req.finish(r) }
        }
    }

    // MARK: серверы

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Каскад-серверы").font(.headline)
            List(selection: Binding<String?>(get: { m.selId.isEmpty ? nil : m.selId }, set: { m.selId = $0 ?? m.selId })) {
                ForEach(m.servers) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("●").foregroundStyle(m.dot(c))
                            Text(c.name).fontWeight(.semibold)
                        }
                        Text(m.subtitle(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            .padding(.leading, 16)
                    }
                    .padding(.vertical, 2)
                    .tag(c.id)
                }
            }
            HStack {
                Button("＋ Сервер…") { Task { await m.addServer() } }
                    .help("SSH-сессия QTerm сервера, который станет каскадом (на нём — 3x-ui, AWG-панель, MTProto)")
                Button("Убрать…") { Task { await m.removeServer() } }
                    .disabled(m.sel == nil)
                    .help("Снять каскад с сервера (перехват снимается первым) или только убрать сервер из списка")
            }
        }
    }

    // MARK: шапка

    private var header: some View {
        HStack(spacing: 8) {
            Text(m.sel?.name ?? "Каскад").font(.title2.bold())
            Text(m.headStatus).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            Spacer()
            if m.busy { ProgressView().controlSize(.small) }
            if m.sel != nil {
                Button(m.installTitle) { Task { await m.installTap() } }
                    .help("Скрипт встроен в QTerm и заливается сам. Установка идёт на сервере в фоне и переживает обрыв SSH")
                Button("Обновить") { Task { await m.refreshWho() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button(m.pending ? "Применить ●" : "Применить") { Task { await m.apply() } }
                    .buttonStyle(.borderedProminent)
                    .tint(m.pending ? .orange : .accentColor)
                    .disabled(m.ready == nil)
                    .help("Пересобрать конфиг mihomo по источникам, группам и правилам: проверка → рестарт → откат при сбое")
            }
        }
    }

    private func cardView(_ card: CascCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(card.title).font(.title3.bold())
                Text(card.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Button(card.button) { Task { await m.cardAction(card.action) } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(18)
            .frame(maxWidth: 640, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch m.seg {
        case .overview: overview
        case .sources: sources
        case .who: who
        case .groups: groupsEditor
        case .rules: rulesEditor
        case .journal: journal
        }
    }

    // MARK: обзор

    private var overview: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Ядро mihomo…") { Task { await m.core() } }
                        .help("Последний стоковый MetaCubeX или своя сборка по ссылке (ff148). С проверкой и откатом")
                    Button("Ссылка на панель mihomo") { Task { await m.dashboard() } }
                        .help("zashboard через SSH-туннель: команда туннеля и secret")
                    Spacer()
                }
                Table(m.groupRows) {
                    TableColumn("") { r in Text("●").foregroundStyle(r.dot) }.width(16)
                    TableColumn("Группа") { r in Text(r.name).bold() }.width(min: 60, ideal: 90)
                    TableColumn("Сейчас") { r in Text(r.node) }.width(min: 80, ideal: 150)
                    TableColumn("Задержка") { r in Text(r.delay) }.width(min: 70, ideal: 110)
                }
                .copyRows { m.groupRows.map { XuiCopy.row([$0.name, $0.node, $0.delay]) }.joined(separator: "\n") }
            }
            .frame(minWidth: 320)
            ScrollView {
                Text(m.info)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(minWidth: 320)
        }
    }

    // MARK: источники

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("＋ Клиент на панели 3x-ui…") { Task { await m.addXuiSource() } }
                    .help("Свой клиент каскада на любой панели (главной или ноде) с нужным набором инбаундов — его Clash-подписка станет источником. Единая подписка клиентов не трогается")
                Button("＋ Ссылка подписки…") { Task { await m.addLinkSource() } }
                    .help("Любая Clash/Mihomo-ссылка — например, подписка отдельной ноды")
                Button("＋ WireGuard / AWG…") { Task { await m.addWgSource() } }
                    .help("Клиент AWG-панели другой ноды или .conf: выход WireGuard/AmneziaWG; можно сделать резервом")
                Divider().frame(height: 18)
                Button("Изменить…") { Task { await m.editSource() } }.disabled(m.sourceSel == nil)
                Button("Вкл / выкл") { Task { await m.toggleSource() } }.disabled(m.sourceSel == nil)
                Button("Удалить…") { Task { await m.deleteSource() } }.disabled(m.sourceSel == nil)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Резерв:").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { m.reserve.isEmpty ? CascadeModel.noReserve : m.reserve },
                                              set: { v in Task { await m.setReserve(v) } })) {
                    ForEach(m.reserveItems, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 240)
                .disabled(m.ready == nil)
                Text("все ноды группы недоступны → трафик группы идёт через резерв; DIRECT не трогается")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Table(m.sourceRows, selection: $m.sourceSel) {
                TableColumn("") { r in Text("●").foregroundStyle(r.dot) }.width(16)
                TableColumn("Источник") { r in Text(r.name).bold() }.width(min: 70, ideal: 120)
                TableColumn("Тип") { r in Text(r.typeText) }.width(min: 60, ideal: 90)
                TableColumn("Откуда") { r in Text(r.src.origin) }.width(min: 160, ideal: 320)
                TableColumn("Префикс") { r in Text(r.src.prefix) }.width(min: 40, ideal: 70)
                TableColumn("Нод") { r in Text(r.nodes) }.width(min: 30, ideal: 45)
                TableColumn("Состояние") { r in Text(r.state) }.width(min: 100, ideal: 280)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { Task { await m.editSource(id) } }
            }
            Text("Источники пишутся на сервер сразу; в работу идут по «Применить» (или сами — таймер сверяет раз в час). " +
                 "Одинаковые имена нод из разных источников — задай префикс.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: кто идёт в каскад

    private var who: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                whoXray
                whoAwg
                whoMtp
                HStack {
                    Text("Пустой перехват (никто) — сервер работает как без каскада.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Применить AWG и MTProto") { Task { await m.applyNf() } }
                        .disabled(m.ready == nil)
                        .help("Сохранить и применить: mihomo перезапустится, правила перехвата встанут заново")
                }
            }
            .padding(.trailing, 8)
        }
    }

    private var whoXray: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Клиенты 3x-ui (VLESS, Hysteria, встроенный AWG)").font(.headline)
                    Spacer()
                    Button("Применить к 3x-ui") { Task { await m.applyXray() } }
                        .disabled(m.ready == nil || !m.hasXui)
                        .help("3x-ui перезапустится — клиенты переподключатся. При сбое шаблон Xray откатывается")
                }
                Text(m.xrayStateText).foregroundStyle(.secondary)
                Picker("", selection: $m.xrayMode) {
                    Text("все").tag("all")
                    Text("выбранные инбаунды").tag("inbounds")
                    Text("выбранные клиенты").tag("users")
                    Text("никто").tag("off")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                .disabled(!m.hasXui)
                if m.xrayMode == "inbounds" { checks(m.xrayInbounds, $m.xraySel) }
                if m.xrayMode == "users" { checks(m.xrayEmails, $m.xraySel) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var whoAwg: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Клиенты AWG-панели этого сервера (WireGuard / AmneziaWG)").font(.headline)
                Text(m.awgStateText).foregroundStyle(.secondary)
                Picker("", selection: $m.awgMode) {
                    Text("все интерфейсы wg* / awg*").tag("all")
                    Text("выбранные интерфейсы").tag("list")
                    Text("никто").tag("off")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                checks(m.awgIfaceItems, $m.awgSel).disabled(m.awgMode != "list")
                HStack {
                    Text("Только адреса клиентов:").foregroundStyle(.secondary)
                    TextField("пусто — все клиенты (10.8.0.2 10.8.0.0/28)", text: $m.awgSrc).textFieldStyle(.roundedBorder)
                }
                Text("TCP и UDP клиентов во внешний мир → mihomo (локальные сети — мимо). IPv6 клиентов через каскад не идёт — отказ, приложения уходят на IPv4.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var whoMtp: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("MTProto-прокси этого сервера (Telegram)").font(.headline)
                Toggle("трафик к Telegram — через каскад, по правилам (группа TG)", isOn: $m.mtpOn)
                Text(m.mtpStateText).foregroundStyle(.secondary)
                HStack {
                    Text("Пользователи процессов:").foregroundStyle(.secondary)
                    TextField("telemt mtproxy", text: $m.mtpUsers).textFieldStyle(.roundedBorder)
                }
                Text("mtg и teleproxy (docker) — по мосту докера, telemt и WEB (mtproto-proxy) — по пользователю процесса. Через каскад идут прямые подключения к DC Telegram (mtg, teleproxy, telemt с use_middle_proxy = false). Middle proxy (порт 8888: сток WEB-прокси, telemt по умолчанию) — напрямую: его рукопожатие привязано к IP сервера, через ноду каскада оно не сходится.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func checks(_ items: [CascCheckItem], _ sel: Binding<Set<String>>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 4) {
            if items.isEmpty { Text("нечего выбирать — «Обновить»").foregroundStyle(.secondary) }
            ForEach(items) { it in
                Toggle(it.text, isOn: Binding(
                    get: { sel.wrappedValue.contains(it.id) },
                    set: { on in if on { sel.wrappedValue.insert(it.id) } else { sel.wrappedValue.remove(it.id) } }))
                    .help(it.id)
            }
        }
        .padding(.leading, 16)
    }

    // MARK: группы, правила, журнал

    private var groupsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("DIRECT →").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { m.directTarget }, set: { v in Task { await m.setDirect(v) } })) {
                    ForEach(m.directItems, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 200)
                .disabled(m.ready == nil)
                .help("Куда идёт DIRECT из правил (ru-трафик, MATCH): напрямую с сервера или через группу (MSK)")
                Text("ИМЯ ТИП ИНТЕРВАЛ УЧАСТНИКИ… — как на Кинетиках; группа на каждую ноду создаётся сама")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer()
                Button("Вернуть") { Task { await m.loadGroups(force: true) } }
                Button("Сохранить и применить") { Task { await m.saveGroups() } }.keyboardShortcut("s", modifiers: .command)
            }
            TextEditor(text: $m.groupsText)
                .font(.system(size: 12, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
        }
    }

    private var rulesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("rule-providers и rules — формат config.yaml Кинетика (пути /opt/etc/mihomo/… переписываются сами). Конфиг с ошибкой не встанет — работает прежний")
                    .foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Вернуть") { Task { await m.loadRules(force: true) } }
                Button("Сохранить и применить") { Task { await m.saveRules() } }.keyboardShortcut("s", modifiers: .command)
            }
            TextEditor(text: $m.rulesText)
                .font(.system(size: 12, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
        }
    }

    private var journal: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Обновить журнал") { Task { await m.loadJournal() } }
                Text("journalctl -u qcascade — последние 300 строк").foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView {
                Text(m.journalText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(6)
            }
            .border(Color.secondary.opacity(0.3))
        }
    }
}
