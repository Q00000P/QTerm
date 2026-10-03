import SwiftUI
import AppKit

/// «Нода из выделения»: итог установщика (3x-ui или AWG) → «новая или переустановка» (по домену подбирает, кого заменить):
/// · 3x-ui — вход по паролю, выпуск API-токена (показывается и прописывается), при переустановке узла —
///   перепривязка на главной (новый адрес + node-sync токен; главная сама зальёт инбаунды и клиентов);
/// · AWG — определение вида панели, при переустановке — пересоздание клиентов старой панели по именам.
/// Порт NodeAddWindow.xaml.cs.
@MainActor
final class NodeAddModel: ObservableObject {
    final class Item: Identifiable {
        let id = UUID()
        let b: InstallBlock
        var kind: String?      // xui | awg | awg1 | nil
        var detected = false
        var name = ""
        var replaceId: String?
        var replace: Bool?     // nil — решим по совпадению адреса/домена
        var token: String?     // выпущенный в этом окне токен 3x-ui
        var tokenFor: String?
        var done = false
        init(_ b: InstallBlock, kind: String?) { self.b = b; self.kind = kind }
        var caption: String { (done ? "✓ " : "") + (name.isEmpty ? b.suggestName() : name) + "  ·  " + PanelProbe.text(kind) }
        var sub: String { b.url.isEmpty ? "ввести вручную" : b.url }
    }

    let store: XuiStore
    @Published var items: [Item] = []
    @Published var curId: UUID?
    private var loading = false

    // форма
    @Published var head = ""
    @Published var kindIdx = 0 { didSet { if !loading && oldValue != kindIdx { kindChanged() } } }
    @Published var replaceMode = false { didSet { if !loading && oldValue != replaceMode { modeChanged() } } }
    @Published var replaceId = "" { didSet { if !loading && oldValue != replaceId { replacePicked() } } }
    @Published var candidates: [XuiPanel] = []
    @Published var name = ""
    @Published var xroleIdx = 0
    @Published var url = ""
    @Published var login = ""
    @Published var password = ""
    @Published var twoFa = ""
    @Published var verify = true
    @Published var tokenShown = ""
    @Published var rebind = true
    @Published var connect = true
    @Published var recreate = true
    @Published var logText = ""
    @Published var busy = false

    var saved: [(id: String, role: String)] = []
    var connectId: String?
    var passwords: [String] = []

    init(store: XuiStore, selection: String) {
        self.store = store
        let blocks = InstallParser.parse(selection)
        items = blocks.map { Item($0, kind: Self.guess($0)) }
        if items.isEmpty { items = [Item(InstallBlock(), kind: PanelProbe.xui)] }
        for it in items { it.name = it.b.suggestName() }
        curId = items[0].id
        show(items[0])
        if blocks.isEmpty {
            log("В буфере нет итога установки. Выдели в терминале блок от «INSTALLATION COMPLETE» (или «Access URL»/«Panel») до AdGuard — выделение сразу копируется — и нажми ⇧⌘A ещё раз. Или заполни поля руками.")
        }
    }

    var cur: Item { items.first { $0.id == curId } ?? items[0] }
    var kind: String { Self.kindOf(kindIdx) }
    var isXui: Bool { kind == PanelProbe.xui }
    var target: XuiPanel? { replaceMode ? candidates.first { $0.id == replaceId } : nil }
    var masters: [XuiPanel] { store.panels().filter(\.isMaster) }

    static func guess(_ b: InstallBlock) -> String? {
        switch b.kind {
        case "xui": return PanelProbe.xui
        case "awg": return b.login.isEmpty ? PanelProbe.awgOld : PanelProbe.awg
        default: return b.login.isEmpty ? nil : PanelProbe.xui
        }
    }

    static func typeIndex(_ k: String?) -> Int { k == PanelProbe.awg ? 1 : k == PanelProbe.awgOld ? 2 : 0 }
    static func kindOf(_ i: Int) -> String { i == 1 ? PanelProbe.awg : i == 2 ? PanelProbe.awgOld : PanelProbe.xui }

    func log(_ s: String) { logText += (logText.isEmpty ? "" : "\n") + s }

    // MARK: вид панели

    func detectAll() async {
        stash(cur)
        var changed: [UUID] = []
        await withTaskGroup(of: (UUID, String?).self) { g in
            for it in items where !it.b.url.isEmpty && !it.detected {
                let u = it.b.url, id = it.id
                g.addTask {
                    if let k = try? await PanelProbe.detect(u, verifyTls: true) { return (id, k) }
                    return (id, try? await PanelProbe.detect(u, verifyTls: false))
                }
            }
            for await (id, k) in g {
                guard let it = items.first(where: { $0.id == id }), let k else { continue }
                if it.kind != k { changed.append(id) }
                it.kind = k
                it.detected = true
            }
        }
        // вид поменялся — «кого заменить» подбираем заново (другой список кандидатов)
        for it in items where changed.contains(it.id) { it.replace = nil; it.replaceId = nil }
        objectWillChange.send()
        if !busy { show(cur) }
    }

    // MARK: форма

    func select(_ id: UUID) {
        guard id != curId, let it = items.first(where: { $0.id == id }) else { return }
        stash(cur)
        curId = id
        show(it)
    }

    func stash(_ it: Item) {
        it.b.url = url.trimmingCharacters(in: .whitespaces)
        it.b.login = login.trimmingCharacters(in: .whitespaces)
        it.b.password = password
        it.name = name.trimmingCharacters(in: .whitespaces)
        it.replace = replaceMode
        it.replaceId = target?.id
    }

    /// Кого, скорее всего, переустановили: тот же адрес → тот же домен.
    static func match(_ cands: [XuiPanel], _ url: String) -> XuiPanel? {
        guard let u = PanelURL.tryParse(url) else { return nil }
        return cands.first { PanelURL.tryParse($0.url) == u }
            ?? cands.first { PanelURL.tryParse($0.url)?.host.caseInsensitiveCompare(u.host) == .orderedSame }
    }

    private func candidatesFor(_ kind: String?) -> [XuiPanel] {
        store.panels().filter { kind == PanelProbe.xui ? $0.isXui : $0.isAwg }
    }

    func show(_ it: Item) {
        loading = true
        let b = it.b
        head = (b.title.isEmpty ? "Панель из выделения" : b.title) + (b.server.isEmpty ? "" : "  ·  сервер \(b.server)")
            + (it.detected ? "\nОпределено по адресу: \(PanelProbe.text(it.kind))" : "")
        url = b.url
        login = b.login
        password = b.password
        twoFa = ""
        tokenShown = it.token ?? ""
        kindIdx = Self.typeIndex(it.kind)
        fillReplace(it)
        name = it.name
        loading = false
    }

    private func fillReplace(_ it: Item) {
        let cands = candidatesFor(it.kind)
        candidates = cands
        let guess = it.replaceId.flatMap { rid in cands.first { $0.id == rid } } ?? Self.match(cands, it.b.url)
        replaceId = guess?.id ?? ""
        let rep = (it.replace ?? (guess != nil)) && !cands.isEmpty && guess != nil
        replaceMode = rep
        if rep, let g = guess, it.replace == nil { it.name = g.name }
    }

    private func kindChanged() {
        stash(cur)
        cur.kind = kind
        cur.replaceId = nil
        cur.replace = nil
        loading = true
        fillReplace(cur)
        name = cur.name
        loading = false
    }

    private func modeChanged() {
        if replaceMode, let p = target { name = p.name }
        else if !replaceMode { name = cur.b.suggestName() }
    }

    private func replacePicked() {
        if let p = candidates.first(where: { $0.id == replaceId }) {
            loading = true
            replaceMode = true
            loading = false
            name = p.name
        }
    }

    var modeNote: String {
        guard let t = target else {
            return "Новая запись в QTerm" + (candidates.isEmpty ? "." : ". Если это переустановка — выбери, кого заменить: имя и место в синке сохранятся.")
        }
        return "«\(t.name)» (\(t.roleText)) получит новый адрес и доступ; имя и запись в синке те же" +
            (Self.match([t], url) == nil ? ". Домен другой — проверь, что выбрана та нода." : ".")
    }

    var showRebind: Bool { isXui && target?.isXuiNode == true && !masters.isEmpty }
    var showConnect: Bool { isXui && target == nil && xroleIdx == 0 && !masters.isEmpty }
    var oldClients: [String]? { !isXui ? (target?.clients.flatMap { $0.isEmpty ? nil : $0 }) : nil }

    // MARK: проверка / сохранение

    private func fromForm() -> XuiPanel? {
        let u = url.trimmingCharacters(in: .whitespaces)
        if PanelURL.tryParse(u) == nil { log("✗ не разобрал адрес"); return nil }
        if password.isEmpty { log("✗ нужен пароль"); return nil }
        if (isXui || kind == PanelProbe.awg) && login.trimmingCharacters(in: .whitespaces).isEmpty { log("✗ нужен логин"); return nil }
        if replaceMode && target == nil { log("✗ выбери, кого заменить"); return nil }
        var n = name.trimmingCharacters(in: .whitespaces)
        let t = target
        if n.isEmpty { let ib = InstallBlock(); ib.url = u; n = t?.name ?? ib.suggestName() }
        // новая, но адрес уже есть в QTerm — обновим ту запись, а не плодим дубль
        let same = t ?? candidatesFor(kind).first { PanelURL.tryParse($0.url) == PanelURL.tryParse(u) }
        var p = same ?? XuiPanel()
        p.name = n
        p.role = isXui ? (t?.role ?? same?.role ?? (xroleIdx == 1 ? "master" : "node")) : kind
        p.url = u
        p.login = kind == PanelProbe.awgOld ? "" : login.trimmingCharacters(in: .whitespaces)
        p.token = isXui ? "" : password
        p.pass = isXui ? password : nil
        p.clients = isXui ? nil : (t?.clients ?? same?.clients)
        p.verifyTls = verify
        p.updatedAt = nil
        return p
    }

    @discardableResult
    private func detect(_ p: XuiPanel) async throws -> String? {
        let k = try await PanelProbe.detect(p.url, verifyTls: p.verifyTls)
        if let k, k != cur.kind {
            log("по адресу — \(PanelProbe.text(k))")
            stash(cur)
            cur.kind = k
            cur.detected = true
            cur.replace = nil
            cur.replaceId = nil
            loading = true
            kindIdx = Self.typeIndex(k)
            fillReplace(cur)
            name = cur.name
            loading = false
        }
        return k
    }

    func test() async {
        guard let p0 = fromForm() else { return }
        busy = true
        defer { busy = false }
        log("━━ проверка " + p0.url)
        do {
            if try await detect(p0) == nil { log("! вид панели не определился — проверяю как выбрано") }
            guard var p = fromForm() else { return }
            if isXui {
                // проверка — только вход, токен выпускается при сохранении (иначе в панели копились бы лишние)
                let r = try await XuiLogin.issueToken(url: p.url, login: p.login, password: password, twoFactor: twoFa,
                                                      verifyTls: p.verifyTls, tokenName: nil)
                log((r.ok ? "" : "✗ ") + r.message)
                return
            }
            p.role = kind
            log(try await AwgProbe.test(&p))
        } catch { log("✗ " + error.localizedDescription) }
    }

    func save() async {
        guard let p = fromForm() else { return }
        let t = target
        let kindBefore = kind
        busy = true
        defer { busy = false }
        log("━━ \(t == nil ? "новая" : "замена «\(t!.name)»"): \(p.url)")
        do { try await detect(p) } catch { log("! " + error.localizedDescription) }
        if kind != kindBefore {
            // список «кого заменить» поменялся — молча не заменяем
            log("! по адресу другой вид панели — проверь «новая / переустановка» и нажми ещё раз")
            return
        }
        do {
            if isXui { try await saveXui(p, t) } else { try await saveAwg(p, t) }
        } catch { log("✗ " + error.localizedDescription) }
    }

    private func saveXui(_ panel: XuiPanel, _ t: XuiPanel?) async throws {
        var p = panel
        // токен: выпущенный в этом окне для того же адреса — не плодим второй
        if let tok = cur.token, !tok.isEmpty, cur.tokenFor == p.url {
            p.token = tok
        } else {
            let f = DateFormatter(); f.dateFormat = "yyMMdd-HHmmss"
            let r = try await XuiLogin.issueToken(url: p.url, login: p.login, password: password, twoFactor: twoFa,
                                                  verifyTls: p.verifyTls, tokenName: "qterm-\(f.string(from: Date()))")
            guard let tok = r.token else { log((r.needTwoFactor ? "! " : "✗ ") + r.message); return }
            log(r.message)
            p.token = tok
            cur.token = tok
            cur.tokenFor = p.url
            tokenShown = tok
        }
        let st = try await XuiAPI.forPanel(p).status()
        log("✓ токен работает · 3x-ui \(J.str(st, "panelVersion"))")
        store.save(p)
        done(p, "✓ «\(p.name)» (\(p.roleText)) \(t == nil ? "сохранена" : "заменена") в QTerm — уйдёт в синк")
        if let t, t.isXuiNode, rebind && showRebind { try await rebindNode(t, p) }
        if t == nil && p.isXuiNode && connect && showConnect {
            connectId = p.id
            log("→ после закрытия окна откроется подключение к главной")
        }
        if t?.isMaster == true {
            log("! переустановлена главная: узлы и клиенты в её базе новые. Бэкапы прежней базы — " + XuiOps.backupDir.path)
        }
    }

    /// Узел на главной указывает на старую панель → новый адрес/порт/путь и node-sync токен с новой.
    /// Главная помечает узел «грязным» и при сверке заливает на ноду свои инбаунды с клиентами.
    private func rebindNode(_ old: XuiPanel, _ neu: XuiPanel) async throws {
        let oldUrl = PanelURL.tryParse(old.url)
        let nu = try PanelURL.parse(neu.url)
        for m in masters {
            let master = try XuiAPI.forPanel(m)
            let nodes: [XNode]
            do { nodes = try await master.nodes() } catch { log("! главная «\(m.name)»: \(error.localizedDescription)"); continue }
            guard let hit = nodes.first(where: { oldUrl?.sameAs($0.address, $0.port, $0.basePath) ?? false })
                ?? nodes.first(where: { $0.name.caseInsensitiveCompare(old.name) == .orderedSame }) else { continue }

            let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"
            let tname = "qterm-master-\(f.string(from: Date()))"
            var sync: String?
            do { sync = try await XuiAPI.forPanel(neu).createToken(tname, scope: "node-sync") }
            catch { log("! node-sync токен не выпустился (\(error.localizedDescription)) — отдам главной админский") }
            let view = try await master.nodeGet(hit.id)
            var mode = J.str(view, "tlsVerifyMode", "verify")
            if !["verify", "skip", "mtls"].contains(mode) { mode = neu.verifyTls ? "verify" : "skip" } // pin: отпечаток у новой другой
            let body: JObj = [
                "name": J.str(view, "name", hit.name), "remark": J.str(view, "remark"),
                "scheme": nu.scheme, "address": nu.host, "port": nu.port, "basePath": nu.basePathOrSlash,
                "apiToken": sync ?? neu.token, "enable": true,
                "allowPrivateAddress": J.bool(view, "allowPrivateAddress"),
                "tlsVerifyMode": mode, "pinnedCertSha256": "",
                "inboundSyncMode": J.str(view, "inboundSyncMode", "all"),
                "inboundTags": (view["inboundTags"] as? [Any]) ?? [Any](),
                "outboundTag": J.str(view, "outboundTag"),
            ]
            try await master.nodeUpdate(hit.id, body)
            log("✓ главная «\(m.name)»: узел «\(hit.name)» → \(nu.host):\(nu.port)\(nu.basePath)" + (sync != nil ? " (на ноде выпущен \(tname))" : ""))
            do { try await master.probeNode(hit.id); log("✓ узел на связи — главная заливает инбаунды и клиентов (минута-две)") }
            catch { log("! проверка узла: " + error.localizedDescription) }
            log("  Если у Hysteria на новой ноде другие пути сертификатов — поправь их в инбаунде на главной.")
            return
        }
        log("! ни на одной главной нет узла со старым адресом или именем «\(old.name)» — подключи его как новый (Узлы → Подключить ноду…)")
    }

    private func saveAwg(_ panel: XuiPanel, _ t: XuiPanel?) async throws {
        var p = panel
        do { log(try await AwgProbe.test(&p)) }
        catch {
            log("✗ " + error.localizedDescription)
            guard XuiDialog.confirm(error.localizedDescription + "\n\nСохранить всё равно? Проверить можно позже во вкладке AWG.",
                                    title: "AWG-нода", yes: "Сохранить") else { return }
            log("сохранено без проверки")
        }
        store.save(p)
        done(p, "✓ «\(p.name)» (\(p.roleText)) \(t == nil ? "сохранена" : "заменена") в QTerm — уйдёт в синк")
        if let old = t?.clients, !old.isEmpty, recreate { try await recreateClients(p, old) }
    }

    private func recreateClients(_ p: XuiPanel, _ names: [String]) async throws {
        let api = try Awg.api(p)
        let have = Set(try await api.clients(p).map { $0.name.lowercased() })
        let ifs = try await api.interfaces()
        var made = 0, skipped = 0
        for n in names {
            if have.contains(n.lowercased()) { skipped += 1; continue }
            // -31 / -20 — клиенты конкретной версии AWG (так их называет «＋ Клиент» → «Оба»)
            var iface: String?
            if n.hasSuffix("-31") { iface = ifs.first { $0.isAwg31 && $0.enabled }?.name }
            else if n.hasSuffix("-20") { iface = ifs.first { !$0.isAwg31 && $0.enabled }?.name }
            do { try await api.create(n, interfaceId: iface); made += 1 }
            catch { log("✗ \(n): \(error.localizedDescription)") }
        }
        log("✓ клиентов создано: \(made)" + (skipped > 0 ? ", уже были: \(skipped)" : "") + " — конфиги и QR во вкладке AWG")
    }

    private func done(_ p: XuiPanel, _ line: String) {
        log(line)
        saved.removeAll { $0.id == p.id }
        saved.append((p.id, p.role))
        if !password.isEmpty { passwords.append(password) }
        cur.done = true
        cur.kind = isXui ? PanelProbe.xui : p.role
        cur.name = p.name
        cur.replaceId = target?.id
        objectWillChange.send()
        if let next = items.first(where: { !$0.done }) { log("→ дальше в выделении: \(next.sub) (выбери слева)") }
    }
}

struct NodeAddSheet: View {
    @StateObject private var m: NodeAddModel
    let finish: ([(id: String, role: String)], String?, [String]) -> Void

    init(store: XuiStore, selection: String, finish: @escaping ([(id: String, role: String)], String?, [String]) -> Void) {
        _m = StateObject(wrappedValue: NodeAddModel(store: store, selection: selection))
        self.finish = finish
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if m.items.count > 1 {
                VStack(alignment: .leading) {
                    Text("Найдено в выделении").foregroundStyle(.secondary)
                    List(m.items, selection: Binding(get: { m.curId }, set: { if let id = $0 { m.select(id) } })) { it in
                        VStack(alignment: .leading) {
                            Text(it.caption).bold()
                            Text(it.sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(it.id)
                    }
                }
                .frame(width: 240)
            }
            VStack(alignment: .leading, spacing: 8) {
                ScrollView { form.padding(.trailing, 6) }
                HStack {
                    if m.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Закрыть") { finish(m.saved, m.connectId, m.passwords) }.keyboardShortcut(.cancelAction)
                    Button("Проверить") { Task { await m.test() } }.disabled(m.busy)
                    Button(m.cur.done ? "Сохранить ещё раз" : m.target == nil ? "Сохранить" : "Заменить") {
                        Task { await m.save() }
                    }
                    .keyboardShortcut(.defaultAction).disabled(m.busy)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, idealWidth: 860, minHeight: 560, idealHeight: 720)
        .task { await m.detectAll() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.head).font(.headline).textSelection(.enabled)
            Picker("Что это за панель", selection: $m.kindIdx) {
                Text("3x-ui").tag(0)
                Text("AWG · awg-panel (логин + пароль)").tag(1)
                Text("AWG · старая amnezia-wg-easy (только пароль)").tag(2)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $m.replaceMode) {
                        Text("Новая нода").tag(false)
                        Text("Переустановка — заменить:").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(m.candidates.isEmpty)
                    Picker("Кого", selection: $m.replaceId) {
                        Text("—").tag("")
                        ForEach(m.candidates) { Text($0.display).tag($0.id) }
                    }
                    .disabled(m.candidates.isEmpty)
                    Text(m.modeNote).foregroundStyle(.secondary).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }
            TextField("Имя в QTerm", text: $m.name)
            if m.isXui && m.target == nil {
                Picker("Роль", selection: $m.xroleIdx) {
                    Text("3x-ui · нода").tag(0)
                    Text("3x-ui · главная").tag(1)
                }
            }
            TextField("Адрес панели (с секретным путём)", text: $m.url)
            if m.kind != PanelProbe.awgOld {
                TextField(m.isXui ? "Логин админа 3x-ui" : "Логин админа awg-panel (2FA должна быть выключена)", text: $m.login)
            }
            SecureField(m.isXui ? "Пароль админа 3x-ui (сохранится в вейлте — чтобы перевыпускать токен)" : "Пароль панели (хранится в вейлте QTerm)",
                        text: $m.password)
            if m.isXui {
                TextField("Код 2FA — только если в панели включена двухфакторка", text: $m.twoFa).frame(width: 340)
            }
            Toggle("Проверять сертификат", isOn: $m.verify)
            if m.showRebind {
                Toggle(isOn: $m.rebind) {
                    Text("Перепривязать узел на главной (\(m.masters.map(\.name).joined(separator: ", "))): новый адрес и токен node-sync. Главная сама зальёт на ноду свои инбаунды и клиентов (те же UUID и ключи Reality — у клиентов ничего не меняется); инбаунды, созданные установщиком, она заменит.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if m.showConnect {
                Toggle("После сохранения подключить к главной — откроется план ревизии имён, как в «Подключить ноду…»", isOn: $m.connect)
            }
            if let old = m.oldClients {
                Toggle(isOn: $m.recreate) {
                    Text("Пересоздать клиентов старой панели (\(old.count)): \(old.joined(separator: ", ")). Ключи будут новые — конфиги и QR раздать заново (вкладка AWG).")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if m.isXui {
                Text("API-токен — выпускается при сохранении (вход по паролю → «Новый токен»), QTerm сразу его пропишет")
                    .foregroundStyle(.secondary).font(.caption)
                HStack {
                    TextField("", text: .constant(m.tokenShown)).font(.system(.body, design: .monospaced)).disabled(m.tokenShown.isEmpty)
                    Button("Копировать") { XuiDialog.copy(m.tokenShown) }.disabled(m.tokenShown.isEmpty)
                }
            }
            ScrollView {
                Text(m.logText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            .frame(minHeight: 90, maxHeight: 200)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        }
        .textFieldStyle(.roundedBorder)
    }
}
