import Foundation
import SwiftUI

// Операции над главной и нодами (склейка имён, подключение ноды, привязки). Порт XuiOps.cs.

/// Склейка группы клиентов главной в одного.
final class MergePlan {
    var key = ""
    var display = ""
    var primary = XClient()
    var secondary: [XClient] = []
    var attach: [Int] = []
    var creds: [String: String] = [:]
}

/// Клиент ноды, который главная не забрала (имя занято): запись ноды убираем,
/// к входящим ноды привязываем клиента главной (ключ Hysteria сохраняем).
final class ReplaceEntry {
    var tags: Set<String> = []
    var auth = ""
    var password = ""
    var emails: [String] = []
}

/// План подключения/ревизии ноды.
final class NodePlan {
    let node: XuiAPI
    let nodeToken: String
    var name = ""
    var existing: XNode?
    var masterMerge: [MergePlan] = []
    var replace: [String: ReplaceEntry] = [:]
    var keep: [String: [String]] = [:]
    var others: [String] = []          // ключи клиентов главной, которых на ноде нет
    var attachOthers = false
    var nodeInboundCount = 0
    var toks: Set<String> = []
    var keyDisplay: [String: String] = [:]
    var approvedMerge: Set<String> = []
    var approvedKeep: Set<String> = []
    var nameOverrides: [String: String] = [:]

    init(node: XuiAPI, nodeToken: String) {
        self.node = node
        self.nodeToken = nodeToken
    }
}

/// Строка плана с галкой: что будет сделано и можно ли это снять.
final class PlanItem: ObservableObject, Identifiable {
    let id = UUID()
    var scope = ""          // главная | имя ноды | имя сервера
    var kind = ""           // merge | replace | keep | attach
    var key = ""
    @Published var result = ""
    var editable = false
    /// Клиент уже сдвоенный (VLESS + Hysteria) — подсветка зелёным.
    var merged = false
    /// Переезд: клиент ищется по ключу имени уже после склейки/переименования.
    var clientKey = ""
    var from = ""
    var note = ""
    var selectable = true
    weak var owner: NodePlan?       // nil — главная
    var email = ""                  // синхронизация: чей клиент
    var ids: [Int] = []             // синхронизация: какие входящие добавить
    @Published var apply = false

    init(scope: String, kind: String, key: String, result: String, from: String, note: String = "",
         apply: Bool, editable: Bool = false, selectable: Bool = true, merged: Bool = false,
         owner: NodePlan? = nil, clientKey: String = "", email: String = "", ids: [Int] = []) {
        self.scope = scope; self.kind = kind; self.key = key; self.result = result; self.from = from
        self.note = note; self.apply = apply; self.editable = editable; self.selectable = selectable
        self.merged = merged; self.owner = owner; self.clientKey = clientKey; self.email = email; self.ids = ids
    }

    var kindText: String {
        switch kind {
        case "merge": return "склеить на главной"
        case "replace": return "дубль на ноде → клиент главной"
        case "keep": return "новый с ноды"
        case "attach": return "добавить на сервер"
        default: return ""
        }
    }

    var kindColor: Color {
        switch kind {
        case "merge": return .blue
        case "replace": return .orange
        case "keep": return .green
        case "attach": return .purple
        default: return .gray
        }
    }

    var asText: String {
        "[\(apply ? "x" : " ")] \(scope)  \(kindText)  \(result)  ← \(from)\(note.isEmpty ? "" : "   · " + note)"
    }
}

@MainActor
final class XuiOps {
    private let names: NameUnifier
    private let log: (String, LogKind) -> Void

    static var backupDir: URL { XuiBackups.dir }

    init(_ names: NameUnifier, log: @escaping (String, LogKind) -> Void) {
        self.names = names
        self.log = log
    }

    private func ok(_ s: String) { log("  ✓ " + s, .ok) }
    private func warn(_ s: String) { log("  ! " + s, .warn) }
    private func err(_ s: String) { log("  ✗ " + s, .err) }
    private func head(_ s: String) { log("━━ " + s, .head) }
    private func dim(_ s: String) { log("  " + s, .dim) }

    // MARK: служебные хвосты: HYS + имена нод + слова из примечаний входящих

    nonisolated static func stripTokens(_ ibs: [XInbound], _ nodes: [XNode], extra: [String] = []) -> Set<String> {
        var t = NameUnifier.suffixTokens
        for n in nodes { t.formUnion(NameUnifier.tokensOf(n.name)) }
        for ib in ibs { t.formUnion(NameUnifier.tokensOf(ib.remark)) }
        for e in extra { t.formUnion(NameUnifier.tokensOf(e)) }
        return t.filter { $0.count >= 2 }
    }

    /// Есть ли среди входящих VLESS-подобные и Hysteria.
    nonisolated static func protos<S: Sequence>(_ ids: S, _ ibById: [Int: XInbound]) -> (v: Bool, h: Bool) where S.Element == Int {
        var v = false, h = false
        for i in ids {
            if let ib = ibById[i], ib.multiUser { if ib.isHys { h = true } else { v = true } }
        }
        return (v, h)
    }

    nonisolated static func byId(_ ibs: [XInbound]) -> [Int: XInbound] {
        Dictionary(ibs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// После привязки/отвязки: имена клиентов из списка (и с индексом) приводим к протоколам —
    /// PC / PC-HYS / PC-SYNC. Ключи и подписка не меняются.
    @discardableResult
    func normalizeIndex(_ m: XuiAPI, _ emails: [String]) async throws -> Int {
        let want = Set(emails)
        let clients = try await m.clients()
        let ibs = try await m.inbounds()
        let ibById = Self.byId(ibs)
        let toks = Self.stripTokens(ibs, try await m.nodes())
        var n = 0
        for c in clients where want.contains(c.email) {
            let key = names.analyze(c.email, toks).key
            let hasIndex = NameUnifier.baseText(c.email) != c.email.trimmingCharacters(in: .whitespaces)
            if !names.isCanonical(key) && !hasIndex { continue }
            let (v, h) = Self.protos(c.inboundIds, ibById)
            let name = names.displayFor(key, [c.email], c.email, vless: v, hys: h)
            if name == c.email || clients.contains(where: { $0.email == name }) { continue }
            do {
                try await m.updateClient(c.email, XuiAPI.clientPayload(c, email: name))
                ok("\(c.email) → \(name)")
                n += 1
            } catch { err("\(c.email): \(error.localizedDescription)") }
        }
        return n
    }

    private static func hysOnly(_ c: XClient, _ ibById: [Int: XInbound]) -> Bool {
        !c.inboundIds.isEmpty && c.inboundIds.allSatisfy { ibById[$0]?.isHys == true }
    }

    // MARK: план склейки на главной

    func planMerge(_ clients: [XClient], _ inbounds: [XInbound], _ nodes: [XNode]) -> [MergePlan] {
        let ibById = Self.byId(inbounds)
        let toks = Self.stripTokens(inbounds, nodes)
        var keyOf: [String: (key: String, hys: Bool)] = [:]
        var groups: [String: [XClient]] = [:]
        for c in clients {
            let a = names.analyze(c.email, toks)
            keyOf[c.email] = a
            groups[a.key, default: []].append(c)
        }

        var plan: [MergePlan] = []
        for key in groups.keys.sorted() {
            let grp = groups[key]!
            // основной — с UUID (VLESS): его ID подписки уже стоит на устройствах
            func rank(_ r: XClient) -> (Int, Int, Int, Int) {
                (!r.uuid.isEmpty && !(keyOf[r.email]?.hys ?? false) ? 0 : 1,
                 Self.hysOnly(r, ibById) ? 1 : 0,
                 !r.uuid.isEmpty ? 0 : 1,
                 r.rid)
            }
            let prim = grp.min { rank($0) < rank($1) }!
            var union: [Int] = []
            for r in grp { for i in r.inboundIds where !union.contains(i) { union.append(i) } }
            let (v, h) = Self.protos(union, ibById)
            let display = names.displayFor(key, grp.map(\.email), prim.email, vless: v, hys: h)
            let sec = grp.filter { $0.email != prim.email }
            var rename = prim.email != display
            if rename && clients.contains(where: { $0.email == display && keyOf[$0.email]?.key != key }) { rename = false }
            // одиночки не из списка не трогаем; из списка — приводим индекс к протоколам
            if sec.isEmpty && (!rename || !names.isCanonical(key)) { continue }

            let p = MergePlan()
            p.key = key
            p.display = rename ? display : prim.email
            p.primary = prim
            p.secondary = sec
            p.attach = union.filter { !prim.inboundIds.contains($0) }
            for s in sec {
                if !s.auth.isEmpty && prim.auth.isEmpty && p.creds["auth"] == nil { p.creds["auth"] = s.auth }
                if !s.password.isEmpty && prim.password.isEmpty && p.creds["password"] == nil { p.creds["password"] = s.password }
                if !s.uuid.isEmpty && prim.uuid.isEmpty && p.creds["id"] == nil { p.creds["id"] = s.uuid }
            }
            plan.append(p)
        }
        return plan
    }

    nonisolated static func label(_ ib: XInbound, _ nodes: [Int: XNode]) -> String {
        let where_: String
        if let n = ib.nodeId { where_ = nodes[n]?.name ?? "узел \(n)" } else { where_ = "главная" }
        return "\(ib.remark.isEmpty ? ib.tag : ib.remark)@\(where_)"
    }

    @discardableResult
    func applyMerge(_ m: XuiAPI, _ plan: [MergePlan]) async -> Int {
        var errors = 0
        for p in plan {
            do {
                for s in p.secondary { try await m.deleteClient(s.email) }
                if p.display != p.primary.email || !p.creds.isEmpty {
                    try await m.updateClient(p.primary.email, XuiAPI.clientPayload(p.primary, email: p.display, creds: p.creds))
                }
                if !p.attach.isEmpty { try await m.attach(p.display, p.attach) }
                ok(p.display)
            } catch {
                errors += 1
                err("\(p.display): \(error.localizedDescription)")
            }
        }
        return errors
    }

    // MARK: бэкапы

    /// База панели → «ИМЯ__vВЕРСИЯ__дата.db» (версия — чтобы было к чему откатываться).
    func backup(_ api: XuiAPI, _ name: String? = nil) async throws -> String {
        try await XuiBackups.save(api, name ?? api.label)
    }

    // MARK: нода: план

    func planNode(_ master: XuiAPI, _ node: XuiAPI, token: String, newName: String?, attachOthers: Bool) async throws -> NodePlan {
        _ = try await node.status()
        let nodes = try await master.nodes()
        let existing = nodes.first { node.url.sameAs($0.address, $0.port, $0.basePath) }
        let trimmed = newName?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = existing?.name ?? (trimmed.isEmpty ? String(node.url.host.split(separator: ".").first ?? "").uppercased() : trimmed)
        if existing == nil && nodes.contains(where: { $0.name == name }) {
            throw XuiError("узел с именем «\(name)» уже есть на главной")
        }

        let mc = try await master.clients()
        let mi = try await master.inbounds()
        let nClients = try await node.clients()
        let nInbounds = try await node.inbounds()
        let nIbById = Self.byId(nInbounds)
        var keepV = Set<String>(), keepH = Set<String>()

        let plan = NodePlan(node: node, nodeToken: token)
        plan.name = name
        plan.existing = existing
        plan.attachOthers = attachOthers
        plan.nodeInboundCount = nInbounds.count
        plan.toks = Self.stripTokens(mi + nInbounds, nodes, extra: [name])
        plan.masterMerge = planMerge(mc, mi, nodes)

        var masterKeys: [String: XClient] = [:]
        for c in mc {
            let k = names.analyze(c.email, plan.toks).key
            if masterKeys[k] == nil { masterKeys[k] = c }
        }
        for p in plan.masterMerge { plan.keyDisplay[p.key] = p.display }

        let nodeIbIds: Set<Int> = existing.map { ex in Set(mi.filter { $0.nodeId == ex.id }.map(\.id)) } ?? []
        let adopted = Set(mc.filter { $0.inboundIds.contains(where: nodeIbIds.contains) }.map(\.email))

        for c in nClients {
            if adopted.contains(c.email) { continue }
            let k = names.analyze(c.email, plan.toks, extraKnown: Array(masterKeys.keys)).key
            let tags = c.inboundIds.compactMap { nIbById[$0]?.tag }
            if masterKeys[k] != nil {
                let r = plan.replace[k] ?? ReplaceEntry()
                plan.replace[k] = r
                r.tags.formUnion(tags)
                r.emails.append(c.email)
                if r.auth.isEmpty { r.auth = c.auth }
                if r.password.isEmpty { r.password = c.password }
            } else {
                plan.keep[k, default: []].append(c.email)
                for ib in c.inboundIds.compactMap({ nIbById[$0] }) where ib.multiUser {
                    if ib.isHys { keepH.insert(k) } else { keepV.insert(k) }
                }
            }
        }

        var keysOnNode = Set(plan.replace.keys)
        for e in adopted { keysOnNode.insert(names.analyze(e, plan.toks).key) }
        plan.others = masterKeys.keys.filter { !keysOnNode.contains($0) }.sorted()

        func disp(_ k: String) -> String {
            if let d = plan.keyDisplay[k] { return d }
            if let c = masterKeys[k] { return c.email }
            if let ke = plan.keep[k] { return names.displayFor(k, ke, ke[0], vless: keepV.contains(k), hys: keepH.contains(k)) }
            return k
        }
        for k in Array(plan.replace.keys) + Array(plan.keep.keys) + plan.others where plan.keyDisplay[k] == nil {
            plan.keyDisplay[k] = disp(k)
        }
        return plan
    }

    // MARK: план с галками

    func mergeItems(_ plan: [MergePlan], scope: String, _ inbounds: [XInbound], _ nodes: [XNode], owner: NodePlan? = nil) -> [PlanItem] {
        let ibById = Self.byId(inbounds)
        let nb = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return plan.map { p in
            let notes = [
                p.display != p.primary.email ? "переименовать \(p.primary.email) → \(p.display)" : "",
                p.secondary.isEmpty ? "" : "убрать записи: \(p.secondary.map(\.email).joined(separator: ", "))",
                p.attach.isEmpty ? "" : "+ " + p.attach.compactMap { ibById[$0] }.map { Self.label($0, nb) }.joined(separator: ", "),
                p.creds["auth"] != nil ? "ключ Hysteria сохранится" : "",
            ].filter { !$0.isEmpty }
            return PlanItem(scope: scope, kind: "merge", key: p.key, result: p.display,
                            from: ([p.primary.email] + p.secondary.map(\.email)).joined(separator: ", "),
                            note: notes.joined(separator: "; "), apply: names.isCanonical(p.key),
                            editable: true, owner: owner)
        }
    }

    func nodeItems(_ p: NodePlan) -> [PlanItem] {
        var items: [PlanItem] = []
        for k in p.replace.keys.sorted() {
            let r = p.replace[k]!
            items.append(PlanItem(scope: p.name, kind: "replace", key: k, result: p.keyDisplay[k] ?? k,
                                  from: r.emails.joined(separator: ", "),
                                  note: "запись ноды убрать, к её входящим привязать клиента главной (VLESS-ключ станет как на главной). Не отмечено — главная эту запись не увидит",
                                  apply: names.isCanonical(k), owner: p))
        }
        for k in p.keep.keys.sorted() {
            let l = p.keep[k]!
            var disp = p.keyDisplay[k] ?? k
            let needMerge = l.count > 1 || (l[0] != disp && names.isCanonical(k))
            if !needMerge { disp = l[0] }
            items.append(PlanItem(scope: p.name, kind: "keep", key: k, result: disp, from: l.joined(separator: ", "),
                                  note: needMerge ? "главная заберёт; отмечено — склеить в одно имя" : "главная заберёт как есть",
                                  apply: needMerge && names.isCanonical(k), editable: needMerge, selectable: needMerge, owner: p))
        }
        for k in p.others {
            items.append(PlanItem(scope: p.name, kind: "attach", key: k, result: p.keyDisplay[k] ?? k,
                                  from: "только на других серверах", note: "привязать ко всем входящим ноды",
                                  apply: p.attachOthers, owner: p))
        }
        return items
    }

    /// Галки → план ноды: снятые дубли не трогаем, снятые склейки не делаем.
    static func applySelection(_ p: NodePlan, _ items: [PlanItem]) {
        let mine = items.filter { $0.owner === p || ($0.owner == nil && $0.kind == "merge") }
        p.approvedMerge = Set(mine.filter { $0.kind == "merge" && $0.apply }.map(\.key))
        p.approvedKeep = Set(mine.filter { $0.kind == "keep" && $0.apply }.map(\.key))
        let rep = Set(mine.filter { $0.kind == "replace" && $0.apply }.map(\.key))
        for k in Array(p.replace.keys) where !rep.contains(k) { p.replace[k] = nil }
        p.others = mine.filter { $0.kind == "attach" && $0.apply }.map(\.key)
        p.attachOthers = !p.others.isEmpty
        p.nameOverrides = overrides(mine)
    }

    /// Ручные правки имён в плане (только отмеченные склейки).
    static func overrides(_ items: [PlanItem]) -> [String: String] {
        var out: [String: String] = [:]
        for i in items where i.editable && i.apply {
            let r = i.result.trimmingCharacters(in: .whitespaces)
            if !r.isEmpty && out[i.key] == nil { out[i.key] = r }
        }
        return out
    }

    static func applyOverrides(_ plan: [MergePlan], _ ov: [String: String]) {
        for m in plan { if let n = ov[m.key] { m.display = n } }
    }

    // MARK: нода: применение

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private func waitAdoption(_ m: XuiAPI, _ nodeId: Int, _ nodeIbCount: Int, timeout: Double = 150) async {
        dim("жду, пока главная заберёт входящие и клиентов ноды (до \(Int(timeout)) с)…")
        let t0 = Date()
        var last: (Int, Int)?
        var stable = 0
        while Date().timeIntervalSince(t0) < timeout {
            if let ibs = try? await m.inbounds().filter({ $0.nodeId == nodeId }),
               let cl = try? await m.clients() {
                let ids = Set(ibs.map(\.id))
                let att = cl.reduce(0) { $0 + $1.inboundIds.filter(ids.contains).count }
                if ibs.count >= nodeIbCount, let l = last, l == (ibs.count, att) {
                    stable += 1
                    if stable >= 2 { ok("импортировано входящих: \(ibs.count), привязок клиентов: \(att)"); return }
                } else { stable = 0 }
                last = (ibs.count, att)
            }
            await sleep(5)
        }
        warn("импорт не завершился за отведённое время — продолжаю с тем, что есть")
    }

    private func nodeEmailsOnMaster(_ m: XuiAPI, _ nodeId: Int) async throws -> Set<String> {
        Set(try await m.inbounds().filter { $0.nodeId == nodeId }.flatMap(\.clientEmails))
    }

    /// После удаления записей прямо на ноде ждём, пока главная перечитает ноду.
    private func waitMasterForgets(_ m: XuiAPI, _ nodeId: Int, _ emails: [String], timeout: Double = 90) async {
        let set = Set(emails)
        if set.isEmpty { return }
        dim("жду, пока главная перечитает ноду…")
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if let now = try? await nodeEmailsOnMaster(m, nodeId), now.isDisjoint(with: set) {
                ok("главная видит ноду без дублей")
                return
            }
            await sleep(5)
        }
        warn("главная всё ещё видит старые записи — продолжаю; при ошибках просто запусти ещё раз")
    }

    /// Возвращает id узла на главной.
    @discardableResult
    func applyNode(_ master: XuiAPI, _ p: NodePlan) async throws -> Int {
        head("Нода «\(p.name)»")
        let b1 = try await backup(master)
        ok("бэкап главной → " + b1)
        let b2 = try await backup(p.node, p.name)
        ok("бэкап ноды → " + b2)
        var errors = 0

        // 1) дубли на самой ноде
        var removed: [String] = []
        for r in p.replace.values {
            for e in r.emails {
                do { try await p.node.deleteClient(e); removed.append(e) }
                catch { err("нода: не удалось удалить \(e): \(error.localizedDescription)"); errors += 1 }
            }
        }
        if !removed.isEmpty { ok("убрал дубли на ноде: \(removed.count)") }
        if let ex = p.existing, !removed.isEmpty { await waitMasterForgets(master, ex.id, removed) }

        // 2) единые имена на главной (план пересчитываем — мог поменяться)
        var nodes = try await master.nodes()
        let merge = planMerge(try await master.clients(), try await master.inbounds(), nodes)
            .filter { p.approvedMerge.contains($0.key) }
        Self.applyOverrides(merge, p.nameOverrides)
        if !merge.isEmpty { errors += await applyMerge(master, merge) }

        // 3) регистрация узла
        var nodeId: Int
        if let ex = p.existing {
            nodeId = ex.id
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMddHHmmss"
            let tname = "qterm-master-\(f.string(from: Date()))"
            var syncToken: String?
            do { syncToken = try await p.node.createToken(tname, scope: "node-sync") }
            catch { warn("ограниченный токен node-sync не создался (\(error.localizedDescription)) — регистрирую с введённым") }
            let body: JObj = [
                "name": p.name, "remark": "", "scheme": p.node.url.scheme, "address": p.node.url.host,
                "port": p.node.url.port, "basePath": p.node.url.basePathOrSlash,
                "apiToken": syncToken ?? p.nodeToken, "enable": true,
                "allowPrivateAddress": Self.isPrivateHost(p.node.url.host),
                "tlsVerifyMode": p.node.verifyTls ? "verify" : "skip", "pinnedCertSha256": "",
                "inboundSyncMode": "all", "inboundTags": [String](), "outboundTag": "",
            ]
            let view = try await master.addNode(body)
            nodeId = (view?["id"] as? NSNumber)?.intValue ?? 0
            if nodeId == 0 { nodeId = try await master.nodes().first { $0.name == p.name }?.id ?? 0 }
            if nodeId == 0 { throw XuiError("узел добавлен, но не нашёл его id") }
            ok("узел «\(p.name)» добавлен (id \(nodeId))\(syncToken != nil ? ", на ноде выпущен токен " + tname : "")")
            await waitAdoption(master, nodeId, p.nodeInboundCount)
        }

        // 4) склейка приехавших с ноды
        nodes = try await master.nodes()
        let merge2 = planMerge(try await master.clients(), try await master.inbounds(), nodes)
            .filter { p.approvedMerge.contains($0.key) || p.approvedKeep.contains($0.key) }
        Self.applyOverrides(merge2, p.nameOverrides)
        if !merge2.isEmpty {
            dim("склеиваю приехавших с ноды:")
            errors += await applyMerge(master, merge2)
        }

        // 5) привязка клиентов главной к входящим ноды
        let mc = try await master.clients()
        let mi = try await master.inbounds()
        let nodeIbs = mi.filter { $0.nodeId == nodeId }
        let prefix = "n\(nodeId)-"
        func ibIdByTag(_ tag: String) -> Int? { nodeIbs.first { $0.tag == tag || $0.tag == prefix + tag }?.id }
        let multi = nodeIbs.filter(\.multiUser).map(\.id)
        var byKey: [String: XClient] = [:]
        for c in mc {
            let k = names.analyze(c.email, p.toks).key
            if byKey[k] == nil { byKey[k] = c }
        }

        var todo: [String: (c: XClient, ids: [Int], r: ReplaceEntry?)] = [:]
        for (k, r) in p.replace {
            guard let c = byKey[k] else { err("не нашёл на главной клиента для \(k)"); errors += 1; continue }
            todo[c.email] = (c, r.tags.compactMap(ibIdByTag), r)
        }
        if p.attachOthers {
            for k in p.others {
                if let c = byKey[k], todo[c.email] == nil { todo[c.email] = (c, multi, nil) }
            }
        }

        for email in todo.keys.sorted() {
            let (c, ids, r) = todo[email]!
            var need: [Int] = []
            for i in ids where !c.inboundIds.contains(i) && !need.contains(i) { need.append(i) }
            if need.isEmpty { continue }
            var over: [String: String] = [:]
            if let r, !r.auth.isEmpty, c.auth.isEmpty { over["auth"] = r.auth }       // ключ Hysteria с ноды
            if let r, !r.password.isEmpty, c.password.isEmpty { over["password"] = r.password }
            for attempt in 1...2 {
                do {
                    if !over.isEmpty {
                        try await master.updateClient(email, XuiAPI.clientPayload(c, creds: over))
                        over.removeAll()
                    }
                    try await master.attach(email, need)
                    ok("\(email) → " + need.compactMap { i in nodeIbs.first { $0.id == i }?.remark }.joined(separator: ", "))
                    break
                } catch {
                    let msg = error.localizedDescription
                    if attempt == 1 && msg.contains("already in use") {
                        warn("\(email): нода ещё держит старую запись — убираю и повторяю")
                        try? await p.node.deleteClient(email)
                        await waitMasterForgets(master, nodeId, [email], timeout: 60)
                        continue
                    }
                    errors += 1
                    err("\(email): \(msg)")
                    break
                }
            }
        }

        // индекс протокола в имени — после привязок мог измениться
        if !todo.isEmpty { try await normalizeIndex(master, Array(todo.keys)) }

        if errors > 0 { warn("ошибок: \(errors); бэкапы в \(Self.backupDir.path); повторный запуск безопасен") }
        else { ok("нода «\(p.name)» готова") }
        return nodeId
    }

    nonisolated static func isPrivateHost(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(first) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                let b = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { v4 -> [UInt8] in
                    withUnsafeBytes(of: v4.pointee.sin_addr.s_addr) { Array($0) }
                }
                if b[0] == 127 || b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
                    (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) { return true }
            } else if ai.pointee.ai_family == AF_INET6, let sa = ai.pointee.ai_addr {
                let b = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { v6 -> [UInt8] in
                    withUnsafeBytes(of: v6.pointee.sin6_addr) { Array($0) }
                }
                let loop = b.dropLast().allSatisfy { $0 == 0 } && b.last == 1
                if loop || (b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) { return true }
            }
            p = ai.pointee.ai_next
        }
        return false
    }
}
