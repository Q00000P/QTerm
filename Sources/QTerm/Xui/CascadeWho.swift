import SwiftUI

// «Кто идёт в каскад»: клиенты 3x-ui (правка шаблона Xray — выход в mihomo), клиенты AWG-панели (nftables tproxy
// с интерфейсов wg*/awg*) и Telegram-трафик MTProto-прокси (mtg/teleproxy — мост докера, telemt/WEB — по
// пользователю процесса). Выбор на экране меняется только по явному действию — автообновление трогает лишь состояние.

struct CascCheckItem: Identifiable {
    let id: String
    let text: String
}

extension CascadeModel {
    private var detectObj: JObj? { sel.flatMap { st($0).detect } }
    private var envObj: JObj { ready?.status["env"] as? JObj ?? [:] }

    var hasXui: Bool {
        guard let r = ready else { return false }
        if let d = detectObj { return J.bool(d, "xui") }
        return J.str(r.status, "xray") != "нет 3x-ui"
    }

    var xrayInbounds: [CascCheckItem] {
        Self.objs(detectObj, "inbounds").map { o in
            let tag = J.str(o, "tag")
            let rm = J.str(o, "remark")
            return CascCheckItem(id: tag, text: "\(rm.isEmpty ? tag : rm)  ·  \(J.str(o, "protocol"))")
        }
    }

    var xrayEmails: [CascCheckItem] { Self.list(detectObj, "emails").map { CascCheckItem(id: $0, text: $0) } }

    var awgIfaceItems: [CascCheckItem] {
        let found = Self.objs(detectObj, "awg").map { (J.str($0, "name"), J.str($0, "addr")) }.filter { !$0.0.isEmpty }
        var items = found.map { CascCheckItem(id: $0.0, text: $0.1.isEmpty ? $0.0 : "\($0.0) (\($0.1))") }
        for n in awgSel where !found.contains(where: { $0.0 == n }) { items.append(CascCheckItem(id: n, text: n + " (нет на сервере)")) }
        return items
    }

    var xrayStateText: String {
        guard let r = ready else { return "" }
        return "сейчас: " + Self.xrayText(J.str(r.status, "xray"))
    }

    var awgStateText: String {
        guard let r = ready else { return "" }
        let found = Self.objs(detectObj, "awg").map { o -> String in
            let n = J.str(o, "name"), a = J.str(o, "addr")
            return a.isEmpty ? n : "\(n) (\(a))"
        }
        let am = J.str(envObj, "awgMode")
        let now = am == "all" ? "все" : am == "list" ? J.str(envObj, "awgIfaces") : "никто"
        return (found.isEmpty ? "WireGuard/AWG-интерфейсов на сервере нет" : "на сервере: " + found.joined(separator: ", ")) +
            " · сейчас: " + now + (am != "off" ? (J.bool(r.status, "nf") ? " · перехват стоит" : " · перехват НЕ стоит") : "")
    }

    var mtpStateText: String {
        guard let r = ready else { return "" }
        let mtp = detectObj?["mtp"] as? JObj
        let users = Self.list(mtp, "users")
        let ctrs = Self.objs(mtp, "containers").map { "\(J.str($0, "name")) (\(J.str($0, "image")))" }
        let found = users.map { "пользователь " + $0 } + ctrs.map { "docker " + $0 }
        return (found.isEmpty ? "MTProto-прокси на сервере не найдено — поставишь потом (скрипт MTProto), перехват подхватит сам"
                              : "найдено: " + found.joined(separator: ", ")) +
            (J.str(envObj, "mtp") == "on" ? (J.bool(r.status, "nf") ? " · перехват стоит" : " · перехват НЕ стоит") : " · сейчас выключено") +
            Self.mtpSinkText(mtp)
    }

    /// Сервер умеет вести WEB-прокси и telemt через каскад (qcascade 2.0.2+).
    var mtpSinkSupported: Bool { ready.map { CascadeRemote.hasMtpSink($0.st.version) } ?? false }

    /// Что сейчас на сервере: сток WEB-прокси и режим telemt (detect qcascade 2.0.2+).
    static func mtpSinkText(_ mtp: JObj?) -> String {
        var t = ""
        if let w = mtp?["web"] as? JObj, J.bool(w, "present") {
            t += J.str(w, "sink") == "telemt" ? "\nWEB-прокси: сток telemt — Telegram через каскад"
                                              : "\nWEB-прокси: сток MTProxy (middle proxy) — Telegram напрямую"
        }
        if let tm = mtp?["telemt"] as? JObj, J.bool(tm, "present") {
            t += J.bool(tm, "middle") ? "\ntelemt: middle proxy — Telegram напрямую" : "\ntelemt: напрямую к DC — Telegram через каскад"
        }
        return t
    }

    /// Для «Обзора»: идут ли WEB-прокси и telemt через каскад; чего на сервере нет (по detect) — не пишем.
    static func mtpSubsText(_ env: JObj, _ mtp: JObj?) -> String {
        if J.str(env, "mtpWeb").isEmpty { return "" }
        var t = ""
        if (mtp?["web"] as? JObj).map({ J.bool($0, "present") }) ?? true {
            t += " · WEB-прокси: " + (J.str(env, "mtpWeb") == "middle" ? "напрямую (middle proxy)" : "через каскад")
        }
        if (mtp?["telemt"] as? JObj).map({ J.bool($0, "present") }) ?? true {
            t += " · telemt: " + (J.str(env, "mtpTelemt") == "middle" ? "напрямую (middle proxy)" : "через каскад")
        }
        return t
    }

    /// Выбор на экране ← настройки сервера (при смене сервера, после установки и по явному «Обновить»).
    func syncWho(full: Bool) {
        guard let r = ready else { whoFor = nil; return }
        guard full else { return }
        whoFor = r.c.id
        let env = envObj
        let xm = J.str(env, "xrayMode")
        xrayMode = ["inbounds", "users", "off"].contains(xm) ? xm : "all"
        xraySel = Set(J.str(env, "xrayList").split(separator: " ").map(String.init))
        let am = J.str(env, "awgMode")
        awgMode = ["list", "off"].contains(am) ? am : "all"
        awgSel = Set(J.str(env, "awgIfaces").split(separator: " ").map(String.init))
        awgSrc = J.str(env, "awgSrc")
        mtpOn = J.str(env, "mtp") == "on"
        let mu = J.str(env, "mtpUsers")
        mtpUsers = mu.isEmpty ? "telemt mtproxy" : mu
        mtpWeb = J.str(env, "mtpWeb") != "middle"
        mtpTelemt = J.str(env, "mtpTelemt") != "middle"
    }

    func refreshWho() async {
        whoFor = nil
        await refresh(detect: true)
    }

    func applyXray() async {
        guard ready != nil else { XuiDialog.info("Каскад на сервере не установлен", title: "Каскад"); return }
        if !hasXui { XuiDialog.info("На сервере нет 3x-ui — перехватывать нечего", title: "Каскад"); return }
        let mode = xrayMode
        let pool = Set((mode == "inbounds" ? xrayInbounds : xrayEmails).map(\.id))
        let list = xraySel.filter { pool.contains($0) }.sorted().joined(separator: " ")
        if (mode == "inbounds" || mode == "users") && list.isEmpty { XuiDialog.info("Ничего не отмечено", title: "Каскад"); return }
        await op("Клиенты 3x-ui через каскад") { _, r in
            try await r.set([("QC_XRAY_MODE", mode), ("QC_XRAY_LIST", mode == "inbounds" || mode == "users" ? list : "")])
            self.log("  3x-ui перезапускается — клиенты переподключатся", .dim)
            let res = try await r.qc(mode == "off" ? "xray off" : "xray on", 240)
            self.logQc(res.out)
            if !res.ok { throw XuiError("перехват не переключился — 3x-ui в прежнем состоянии (причина выше)") }
        }
    }

    func applyNf() async {
        guard ready != nil else { XuiDialog.info("Каскад на сервере не установлен", title: "Каскад"); return }
        let am = awgMode
        let ifs = awgSel.sorted().joined(separator: " ")
        if am == "list" && ifs.isEmpty { XuiDialog.info("Отметь интерфейсы AWG-панели", title: "Каскад"); return }
        let src = awgSrc.replacingOccurrences(of: #"[\s,;]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if src.range(of: #"^[0-9./ ]*$"#, options: .regularExpression) == nil {
            XuiDialog.info("Адреса клиентов — IPv4-адреса или подсети через пробел", title: "Каскад"); return
        }
        let users = mtpUsers.replacingOccurrences(of: #"[\s,;]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if users.range(of: #"^[A-Za-z0-9._ -]*$"#, options: .regularExpression) == nil {
            XuiDialog.info("Пользователи — системные имена через пробел", title: "Каскад"); return
        }
        let mtp = mtpOn ? "on" : "off"
        var kv = [("QC_AWG_MODE", am), ("QC_AWG_IFACES", ifs), ("QC_AWG_SRC", src),
                  ("QC_MTP", mtp), ("QC_MTP_USERS", users.isEmpty ? "telemt mtproxy" : users)]
        if mtpSinkSupported {   // старый qcascade этих ключей не знает — «set» упал бы целиком
            kv += [("QC_MTP_WEB", mtpWeb ? "direct" : "middle"), ("QC_MTP_TELEMT", mtpTelemt ? "direct" : "middle")]
        }
        let env = kv
        await op("AWG-панель и MTProto через каскад") { c, r in
            try await r.set(env)
            try await self.applyCore(c, r)
        }
    }
}
