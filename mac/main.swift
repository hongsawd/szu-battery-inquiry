// 深大电量 · macOS 版（菜单栏）
// 数据来源：校内电控系统 http://192.168.84.3:9090/cgcSims/
//
// 编译：./build.sh          产物：深大电量.app
// 自检：./深大电量.app/Contents/MacOS/SzuPower --selftest

import Cocoa
import SwiftUI
import Carbon.HIToolbox

// ============================ 配置与缓存 ============================

final class Store {
    static let shared = Store()
    let dir: URL
    let cfgURL: URL
    let cacheURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("szu-power", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cfgURL = dir.appendingPathComponent("config.json")
        cacheURL = dir.appendingPathComponent("cache.json")
    }

    func loadConfig() -> [String: Any]? {
        guard let d = try? Data(contentsOf: cfgURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }

    func saveConfig(_ c: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted]) else { return }
        try? d.write(to: cfgURL)
    }

    func loadCache() -> [String: Any]? {
        guard let d = try? Data(contentsOf: cacheURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }

    func saveCache(_ c: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: c) else { return }
        try? d.write(to: cacheURL)
    }
}

func cfgString(_ c: [String: Any]?, _ k: String, _ def: String) -> String {
    guard let v = c?[k] as? String, !v.isEmpty else { return def }
    return v
}

func cfgDouble(_ c: [String: Any]?, _ k: String, _ def: Double) -> Double {
    if let n = c?[k] as? NSNumber { return n.doubleValue }
    if let s = c?[k] as? String, let n = Double(s) { return n }
    return def
}

func cfgBool(_ c: [String: Any]?, _ k: String, _ def: Bool) -> Bool {
    if let b = c?[k] as? Bool { return b }
    if let n = c?[k] as? NSNumber { return n.boolValue }
    return def
}

// ============================ 电控系统接口 ============================

enum GBK {
    static let encoding: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String.Encoding(rawValue: cf)
    }()

    /// 中文楼栋/房间名要按 GBK 百分号编码，服务端才认
    static func percent(_ s: String) -> String {
        guard let d = s.data(using: encoding) else { return s }
        return d.map { String(format: "%%%02X", $0) }.joined()
    }

    static func decode(_ d: Data) -> String {
        return String(data: d, encoding: encoding) ?? String(data: d, encoding: .utf8) ?? ""
    }
}

struct Row: Equatable {
    let date: String
    let remain: Double
    let used: Double
    let bought: Double
}

struct Snapshot {
    var date: String
    var remain: Double
    var dayUse: Double?
    var avg: Double
    var avgDays: Int
    var series: [(label: String, value: Double)]
    var fetchedAt: Date
    var roomId: String
}

enum SzuError: LocalizedError {
    case http(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .http(let m): return m
        case .parse(let m): return m
        }
    }
}

enum SzuAPI {
    static let base = "http://192.168.84.3:9090/cgcSims"

    static func call(_ path: String, _ body: String?) throws -> String {
        guard let url = URL(string: base + path) else { throw SzuError.http("地址不对") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue(base + "/login.do", forHTTPHeaderField: "Referer")
        if let b = body {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = b.data(using: .ascii)
        }

        var result: Result<String, Error>?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { result = .failure(err); return }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(SzuError.http("服务器返回 \(http.statusCode)"))
                return
            }
            guard let d = data else { result = .failure(SzuError.http("没有返回内容")); return }
            result = .success(GBK.decode(d))
        }.resume()
        _ = sem.wait(timeout: .now() + 25)

        switch result {
        case .success(let s): return s
        case .failure(let e): throw e
        case .none: throw SzuError.http("连不上电控系统（要在校园网内）")
        }
    }

    static func buildings(client: String) throws -> [(id: String, name: String)] {
        let html = try call("/login.do?task=station&client=" + client, nil)
        let rx = try NSRegularExpression(pattern: "<option value=\"(\\d+)\">([^<]+)</option>")
        let ns = html as NSString
        return rx.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let id = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : (id, name)
        }
    }

    static func resolveRoomId(client: String, building: String, room: String) throws -> String {
        let list = try buildings(client: client)
        guard let hit = list.first(where: { $0.name == building }) else {
            throw SzuError.parse("电控系统里没有楼栋「\(building)」")
        }
        let body = "client=\(client)&buildingId=\(hit.id)&buildingName=\(GBK.percent(building))"
            + "&roomName=\(GBK.percent(room))&select=%20%B2%E9%D1%AF%20"
        let html = try call("/login.do", body)
        guard let v = firstGroup(html, "name=\"roomId\"\\s+value=\"(\\d+)\"") else {
            throw SzuError.parse("房间「\(room)」没查到，确认是 \(building) 里的三位房间号")
        }
        return v
    }

    /// 服务端单次最多回 20 条，所以分两段抓
    static func rows(client: String, roomId: String, room: String, from: Date, to: Date) throws -> [Row] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let body = "hiddenType=&isHost=&beginTime=\(f.string(from: from))&endTime=\(f.string(from: to))"
            + "&type=2&client=\(client)&roomId=\(roomId)&roomName=\(GBK.percent(room))&building="
        let html = try call("/selectList.do", body)
        return parseRows(html)
    }

    static func parseRows(_ html: String) -> [Row] {
        let pattern = "(?s)<tr[^>]*>\\s*<td width=\"13%\"[^>]*>\\s*(\\d+)\\s*</td>\\s*"
            + "<td width=\"13%\"[^>]*>\\s*([^<]*?)\\s*</td>\\s*"
            + "<td width=\"13%\"[^>]*>\\s*([\\d.]+)\\s*</td>\\s*"
            + "<td width=\"13%\"[^>]*>\\s*([\\d.]+)\\s*</td>\\s*"
            + "<td width=\"13%\"[^>]*>\\s*([\\d.]+)\\s*</td>\\s*"
            + "<td width=\"22%\"[^>]*>\\s*(\\d{4}-\\d{2}-\\d{2})"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        return rx.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let remain = Double(ns.substring(with: m.range(at: 3)))
            let used = Double(ns.substring(with: m.range(at: 4)))
            let bought = Double(ns.substring(with: m.range(at: 5)))
            let date = ns.substring(with: m.range(at: 6))
            guard let r = remain, let u = used, let b = bought else { return nil }
            return Row(date: date, remain: r, used: u, bought: b)
        }
    }

    static func firstGroup(_ s: String, _ pattern: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: 组装

    static func snapshot(cfg: [String: Any]) throws -> Snapshot {
        let client = cfgString(cfg, "client", "192.168.84.110")
        let building = cfgString(cfg, "building", "冬筑3-6楼")
        let room = cfgString(cfg, "room", "520")
        var roomId = cfgString(cfg, "roomId", "")

        if roomId.isEmpty {
            roomId = try resolveRoomId(client: client, building: building, room: room)
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var all = try rows(client: client, roomId: roomId, room: room,
                           from: cal.date(byAdding: .day, value: -19, to: today)!,
                           to: cal.date(byAdding: .day, value: -1, to: today)!)
        // 第一段拿满了才补第二段（说明可能还有更早的）
        if all.count >= 18 {
            let older = try rows(client: client, roomId: roomId, room: room,
                                 from: cal.date(byAdding: .day, value: -34, to: today)!,
                                 to: cal.date(byAdding: .day, value: -20, to: today)!)
            all.append(contentsOf: older)
        }

        var dict: [String: Row] = [:]
        for r in all { dict[r.date] = r }
        let list = dict.values.sorted { $0.date < $1.date }

        guard let last = list.last else {
            throw SzuError.parse("房间 \(room) 查到了，但没有用电数据（系统还没更新，或房间号不对）")
        }

        // 逐日用量 = 相邻两天总用电差，按间隔天数摊平
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        var daily: [(date: String, value: Double)] = []
        for i in 1..<max(list.count, 1) {
            guard let a = dayFormatter.date(from: list[i - 1].date),
                  let b = dayFormatter.date(from: list[i].date) else { continue }
            let gap = cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 0
            if gap < 1 || gap > 3 { continue }
            let d = ((list[i].used - list[i - 1].used) / Double(gap) * 100).rounded() / 100
            daily.append((list[i].date, d))
        }

        let series = daily.suffix(5).map { (label: String($0.date.suffix(5)), value: max($0.value, 0)) }

        var valid = daily.map { $0.value }.filter { $0 > 0 && $0 <= 80 }
        if valid.isEmpty { valid = daily.map { $0.value }.filter { $0 > 0 } }
        let avg = valid.isEmpty ? 0 : ((valid.reduce(0, +) / Double(valid.count)) * 100).rounded() / 100

        let dayUse: Double?
        if let lastDaily = daily.last {
            dayUse = lastDaily.value
        } else if list.count >= 2 {
            dayUse = ((last.used - list[list.count - 2].used) * 100).rounded() / 100
        } else {
            dayUse = nil
        }

        return Snapshot(date: last.date, remain: last.remain, dayUse: dayUse, avg: avg,
                        avgDays: valid.count, series: series, fetchedAt: Date(), roomId: roomId)
    }
}

// ============================ 预警文案 ============================

struct WarnInfo {
    var text: String
    var sticky: Bool
}

func warnInfo(snap: Snapshot, cfg: [String: Any]) -> WarnInfo? {
    let below = cfgDouble(cfg, "warnBelow", 20)
    guard below > 0, snap.remain < below else { return nil }

    var s = "⚠ 电量偏低：" + String(format: "%.1f", snap.remain) + " 度"
    if snap.avg > 0 {
        let days = (snap.remain / snap.avg * 10).rounded() / 10
        let d = String(format: "%.1f", days)
        if days < 2 { s += "，约 \(d) 天，今晚的空调可能就撑不过去了" }
        else if days < 4 { s += "，约 \(d) 天，撑不过两晚空调" }
        else { s += "，约 \(d) 天" }
    }
    s += "。记得充值。"

    let ackDate = cfgString(cfg, "warnAckDate", "")
    let ackRemain = cfgDouble(cfg, "warnAckRemain", -1)
    let same = (ackDate == snap.date) && (snap.remain >= ackRemain - 0.5)
    return WarnInfo(text: s, sticky: !same)
}

// ============================ 卡片界面 ============================

func color(_ hex: String) -> Color {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    let a = Double((v >> 24) & 0xFF) / 255
    let r = Double((v >> 16) & 0xFF) / 255
    let g = Double((v >> 8) & 0xFF) / 255
    let b = Double(v & 0xFF) / 255
    return Color(red: r, green: g, blue: b).opacity(a)
}

struct Palette {
    var card: Color
    var border: Color
    var title: Color
    var sub: Color
    var accent: Color
    var grid: Color
    var err: Color
    var chip: Color

    static func of(_ theme: String) -> Palette {
        let dark: Bool
        switch theme {
        case "light": dark = false
        case "dark": dark = true
        default:
            let best = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            dark = (best == .darkAqua)
        }
        return dark
            ? Palette(card: color("#F52B2B2B"), border: color("#26FFFFFF"), title: .white,
                      sub: color("#8CFFFFFF"), accent: color("#4CC2FF"), grid: color("#18FFFFFF"),
                      err: color("#FF6B6B"), chip: color("#0CFFFFFF"))
            : Palette(card: color("#FFFFFFFF"), border: color("#22000000"), title: color("#E4000000"),
                      sub: color("#8A000000"), accent: color("#0F6CBD"), grid: color("#12000000"),
                      err: color("#C42B1C"), chip: color("#0C000000"))
    }
}

struct Sparkline: View {
    var points: [Double]
    var labels: [String]
    var accent: Color
    var grid: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height - 16
            let maxV = max(points.max() ?? 1, 1)
            let step = points.count > 1 ? w / CGFloat(points.count - 1) : w
            ZStack(alignment: .topLeading) {
                ForEach(0..<3) { i in
                    let y = h * CGFloat(i) / 2
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }.stroke(grid, lineWidth: 1)
                }
                Path { p in
                    for (i, v) in points.enumerated() {
                        let x = CGFloat(i) * step
                        let y = h - CGFloat(v / maxV) * h
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }.stroke(accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                ForEach(Array(points.enumerated()), id: \.offset) { i, v in
                    let x = CGFloat(i) * step
                    let y = h - CGFloat(v / maxV) * h
                    Circle().fill(accent).frame(width: 6, height: 6)
                        .position(x: x, y: y)
                    Text(String(format: "%.2g", v))
                        .font(.system(size: 9)).foregroundColor(accent.opacity(0.9))
                        .position(x: x, y: max(y - 14, 8))
                    Text(labels.indices.contains(i) ? labels[i] : "")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                        .position(x: x, y: h + 12)
                }
            }
        }
    }
}

struct CardView: View {
    var title: String
    var subtitle: String
    var remain: String
    var day: String
    var avg: String
    var series: [Double]
    var labels: [String]
    var warn: String?
    var palette: Palette
    var onSettings: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(palette.accent.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Text("⚡").font(.system(size: 14)).foregroundColor(palette.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundColor(palette.title)
                    Text(subtitle).font(.system(size: 11)).foregroundColor(palette.sub)
                }
                Spacer()
                Button(action: onSettings) { Image(systemName: "gearshape").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(palette.sub).frame(width: 22, height: 22)
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundColor(palette.sub).frame(width: 22, height: 22)
            }
            .padding(.bottom, 6)

            if let w = warn {
                Text(w)
                    .font(.system(size: 11.5))
                    .foregroundColor(palette.err)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.err.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.err.opacity(0.35), lineWidth: 1))
                    .padding(.bottom, 10)
            }

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(remain).font(.system(size: 30, weight: .light)).foregroundColor(palette.title)
                Text(" 度").font(.system(size: 12)).foregroundColor(palette.sub).padding(.bottom, 5)
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("昨日用电").font(.system(size: 10)).foregroundColor(palette.sub)
                    Text(day).font(.system(size: 15)).foregroundColor(palette.title)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("平均用电").font(.system(size: 10)).foregroundColor(palette.sub)
                    Text(avg).font(.system(size: 15)).foregroundColor(palette.title)
                }.padding(.leading, 14)
            }
            .padding(.bottom, 8)

            Text("近 5 天每日用电（度）").font(.system(size: 9.5)).foregroundColor(palette.sub)
            Sparkline(points: series, labels: labels, accent: palette.accent, grid: palette.grid)
                .frame(height: 76)
                .padding(.top, 4)
        }
        .padding(15)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(palette.card)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
        )
    }
}

// ============================ 设置界面 ============================

struct SettingsView: View {
    @State var theme: String
    @State var campus: String
    @State var building: String
    @State var room: String
    @State var hotkey: String
    @State var autostart: Bool
    @State var holdSeconds: Double
    @State var warnBelow: Double
    @State var warnText: String
    @State var status: String = ""

    var buildings: [String]
    var onSave: ([String: Any]) -> String?
    var onCancel: () -> Void

    /// 一行“标签 + 控件”，不用 Grid（Grid 要 macOS 13）
    func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 62, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("深大电量 · 设置").font(.system(size: 15, weight: .semibold))
            Text("填完保存，之后想改再点卡片上的齿轮").font(.system(size: 11)).foregroundColor(.secondary)

            Divider()

            row("主题") {
                Picker("", selection: $theme) {
                    Text("深色").tag("dark")
                    Text("浅色").tag("light")
                    Text("跟随系统").tag("auto")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            row("校区") {
                TextField("南校区", text: $campus).textFieldStyle(.roundedBorder)
            }
            row("楼栋") {
                Picker("", selection: $building) {
                    if !buildings.contains(building) && !building.isEmpty {
                        Text(building).tag(building)
                    }
                    ForEach(buildings, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 240)
            }
            row("房间号") {
                TextField("三位，如 520", text: $room).textFieldStyle(.roundedBorder).frame(width: 120)
            }
            row("快捷键") {
                TextField("CTRL + ALT + E（留空 = 不设）", text: $hotkey).textFieldStyle(.roundedBorder)
            }
            row("开机自启") {
                Toggle("登录时启动，常驻菜单栏", isOn: $autostart).toggleStyle(.checkbox)
            }
            row("卡片停留") {
                HStack(spacing: 8) {
                    Picker("", selection: $holdSeconds) {
                        Text("20 秒").tag(20.0)
                        Text("45 秒").tag(45.0)
                        Text("1 分钟").tag(60.0)
                        Text("3 分钟").tag(180.0)
                        Text("不自动关").tag(0.0)
                    }.labelsHidden().frame(width: 130)
                    Stepper("", value: $holdSeconds, in: 0...3600, step: 5).labelsHidden()
                    Text(holdSeconds == 0 ? "手动关" : "\(Int(holdSeconds)) 秒")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            row("低电量预警") {
                HStack(spacing: 6) {
                    TextField("20", text: $warnText).textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("度以下提醒（0 = 关）").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }

            if !status.isEmpty {
                Text(status).font(.system(size: 11)).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") {
                    let wb = Double(warnText.trimmingCharacters(in: .whitespaces)) ?? warnBelow
                    let payload: [String: Any] = [
                        "theme": theme, "campus": campus, "building": building, "room": room,
                        "hotkey": hotkey, "autostart": autostart,
                        "holdSeconds": Int(holdSeconds), "warnBelow": wb
                    ]
                    if let err = onSave(payload) { status = err } else { status = "" }
                }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 460)
    }
}

// ============================ 应用主体 ============================

final class Model {
    static let shared = Model()
    var cfg: [String: Any] = [:]
    var snap: Snapshot?
    var errorText: String?
    var warn: WarnInfo?

    var holdSeconds: Int { Int(cfgDouble(cfg, "holdSeconds", 20)) }
    var theme: String { cfgString(cfg, "theme", "dark") }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover?
    var closeTimer: Timer?
    var refreshTimer: Timer?
    var hotKeyRef: EventHotKeyRef?
    var settingsWindow: NSWindow?
    var buildings: [String] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let c = Store.shared.loadConfig() { Model.shared.cfg = c }
        else { Model.shared.cfg = ["theme": "dark", "campus": "南校区", "client": "192.168.84.110",
                                   "building": "冬筑3-6楼", "room": "", "hotkey": "CTRL + ALT + E",
                                   "autostart": true, "holdSeconds": 20, "warnBelow": 20] }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "深大电量")
            b.image?.isTemplate = true
            b.action = #selector(togglePopover)
            b.target = self
        }

        registerHotKey()
        refresh()

        // 电量提醒：启动时如果已经低于阈值，直接弹一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if let s = Model.shared.snap, warnInfo(snap: s, cfg: Model.shared.cfg) != nil {
                self.showCard()
            }
        }

        // 每 30 分钟刷新一次（电控一天才更新，不用勤）
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        if !cfgString(Model.shared.cfg, "room", "").isEmpty, Model.shared.errorText == nil {
            // 配置齐全时尝试静默刷新状态栏
            updateStatusTitle()
        }
    }

    // MARK: 数据

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            do {
                let s = try SzuAPI.snapshot(cfg: Model.shared.cfg)
                Model.shared.snap = s
                Model.shared.errorText = nil
                Model.shared.warn = warnInfo(snap: s, cfg: Model.shared.cfg)
                if s.roomId != cfgString(Model.shared.cfg, "roomId", "") {
                    Model.shared.cfg["roomId"] = s.roomId
                    Store.shared.saveConfig(Model.shared.cfg)
                }
                var cache: [String: Any] = [
                    "ts": ISO8601DateFormatter().string(from: Date()),
                    "remain": s.remain, "date": s.date,
                    "avg": s.avg,
                    "series": s.series.map { ["label": $0.label, "value": $0.value] }
                ]
                if let d = s.dayUse { cache["dayUse"] = d }
                Store.shared.saveCache(cache)
            } catch {
                Model.shared.errorText = error.localizedDescription
                Model.shared.warn = nil
            }
            DispatchQueue.main.async { self.updateStatusTitle() }
        }
    }

    func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        if let s = Model.shared.snap {
            button.image = NSImage(systemSymbolName: Model.shared.warn != nil ? "bolt.badge.clock.fill" : "bolt.fill",
                                   accessibilityDescription: "深大电量")
            button.image?.isTemplate = true
            button.title = String(format: " %.0f", s.remain)
        } else {
            button.title = ""
        }
    }

    // MARK: 卡片

    @objc func togglePopover() {
        if let p = popover, p.isShown { hideCard() } else { showCard() }
    }

    func showCard() {
        hideCard()

        let pal = Palette.of(Model.shared.theme)
        let cfg = Model.shared.cfg
        let s = Model.shared.snap
        let title = "深大电量 · " + cfgString(cfg, "campus", "南校区") + " "
            + cfgString(cfg, "building", "") + " " + cfgString(cfg, "room", "")

        var subtitle = "还没有数据"
        var remain = "--"
        var day = "--"
        var avg = "--"
        var series: [Double] = []
        var labels: [String] = []

        if let e = Model.shared.errorText {
            subtitle = "查询失败 · " + e
        } else if let s = s {
            subtitle = "数据 " + s.date
            if s.avg > 0 { subtitle += " · 约还可用 \(Int(floor(s.remain / s.avg))) 天" }
            remain = String(format: "%.2f", s.remain)
            if let d = s.dayUse { day = String(format: "%.2f", d) }
            if s.avg > 0 { avg = String(format: "%.2f", s.avg) }
            series = s.series.map { $0.value }
            labels = s.series.map { $0.label }
        }

        let view = CardView(
            title: title, subtitle: subtitle, remain: remain, day: day, avg: avg,
            series: series, labels: labels, warn: Model.shared.warn?.text, palette: pal,
            onSettings: { [weak self] in self?.openSettings() },
            onClose: { [weak self] in self?.hideCard() }
        )

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = NSHostingController(rootView: view)
        popover = pop

        if let button = statusItem.button {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        let hold = Model.shared.holdSeconds
        let sticky = Model.shared.warn?.sticky ?? false
        if hold > 0 && !sticky {
            closeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(hold), repeats: false) { [weak self] _ in
                self?.hideCard()
            }
        }
    }

    func hideCard() {
        closeTimer?.invalidate(); closeTimer = nil
        guard let p = popover else { return }
        // 关掉时记一笔"这条预警看过了"，同一读数不再粘住
        if let w = Model.shared.warn, w.sticky, let s = Model.shared.snap {
            Model.shared.cfg["warnAckDate"] = s.date
            Model.shared.cfg["warnAckRemain"] = s.remain
            Store.shared.saveConfig(Model.shared.cfg)
            Model.shared.warn = WarnInfo(text: w.text, sticky: false)
        }
        p.performClose(nil)
        popover = nil
    }

    // MARK: 设置

    func openSettings() {
        hideCard()
        if let w = settingsWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let cfg = Model.shared.cfg
        let view = SettingsView(
            theme: cfgString(cfg, "theme", "dark"),
            campus: cfgString(cfg, "campus", "南校区"),
            building: cfgString(cfg, "building", "冬筑3-6楼"),
            room: cfgString(cfg, "room", ""),
            hotkey: cfgString(cfg, "hotkey", "CTRL + ALT + E"),
            autostart: cfgBool(cfg, "autostart", true),
            holdSeconds: cfgDouble(cfg, "holdSeconds", 20),
            warnBelow: cfgDouble(cfg, "warnBelow", 20),
            warnText: String(format: "%.0f", cfgDouble(cfg, "warnBelow", 20)),
            buildings: buildings,
            onSave: { [weak self] payload in
                guard let self = self else { return "内部错误" }
                var p = payload
                let room = (p["room"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard room.count == 3 else { return "房间号要三位，例如 520" }
                p["room"] = room
                p["client"] = cfgString(Model.shared.cfg, "client", "192.168.84.110")
                do {
                    p["roomId"] = try SzuAPI.resolveRoomId(client: p["client"] as! String,
                                                          building: p["building"] as! String, room: room)
                } catch {
                    return error.localizedDescription
                }
                p["warnAckDate"] = cfgString(Model.shared.cfg, "warnAckDate", "")
                p["warnAckRemain"] = cfgDouble(Model.shared.cfg, "warnAckRemain", -1)
                Model.shared.cfg = p
                Store.shared.saveConfig(p)
                self.applyLoginItem(p["autostart"] as? Bool ?? true)
                self.registerHotKey()
                self.settingsWindow?.close()
                self.settingsWindow = nil
                self.refresh()
                return nil
            },
            onCancel: { [weak self] in
                self?.settingsWindow?.close()
                self?.settingsWindow = nil
            }
        )

        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.title = "深大电量 · 设置"
        win.styleMask = [.titled, .closable]
        win.center()
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        DispatchQueue.global(qos: .utility).async {
            if let list = try? SzuAPI.buildings(client: cfgString(Model.shared.cfg, "client", "192.168.84.110")) {
                DispatchQueue.main.async { self.buildings = list.map { $0.name } }
            }
        }
    }

    // MARK: 登录项

    func applyLoginItem(_ on: Bool) {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.hongsawd.szupower.plist")
        if on {
            let exe = Bundle.main.executablePath ?? ""
            let body = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>com.hongsawd.szupower</string>
              <key>ProgramArguments</key><array><string>\(exe)</string></array>
              <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            try? body.write(to: plist, atomically: true, encoding: .utf8)
            _ = shell("/bin/launchctl", ["unload", plist.path])
            _ = shell("/bin/launchctl", ["load", plist.path])
        } else {
            _ = shell("/bin/launchctl", ["unload", plist.path])
            try? FileManager.default.removeItem(at: plist)
        }
    }

    @discardableResult
    func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: d, encoding: .utf8) ?? ""
    }

    // MARK: 全局热键（Carbon）

    func registerHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        let spec = cfgString(Model.shared.cfg, "hotkey", "CTRL + ALT + E")
        guard let hk = parseHotkey(spec) else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { AppDelegate.current?.togglePopover() }
            return noErr
        }, 1, &eventType, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x53505557), id: 1) // 'SPUW'
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(hk.code), UInt32(hk.mods), id, GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
    }

    static weak var current: AppDelegate?

    func parseHotkey(_ spec: String) -> (code: Int, mods: Int)? {
        let parts = spec.uppercased().components(separatedBy: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var mods = 0
        var key: String?
        for p in parts {
            switch p {
            case "CTRL", "CONTROL", "CMDORCTRL": mods |= controlKey
            case "ALT", "OPTION", "OPT": mods |= optionKey
            case "SHIFT": mods |= shiftKey
            case "WIN", "CMD", "COMMAND", "META": mods |= cmdKey
            default: key = p
            }
        }
        guard let k = key else { return nil }
        let letters: [String: Int] = ["A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
                                      "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
                                      "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
                                      "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
                                      "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
                                      "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
                                      "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
                                      "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
                                      "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
                                      "8": kVK_ANSI_8, "9": kVK_ANSI_9]
        if let c = letters[k] { return (c, mods) }
        if k.hasPrefix("F"), let n = Int(k.dropFirst()), n >= 1, n <= 12 {
            let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                         kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            return (fkeys[n - 1], mods)
        }
        return nil
    }
}

// ============================ 自检（在 CI 里跑） ============================

let sampleHTML = """
<tr height="22"><td width="13%">1</td><td width="13%">-</td>
<td width="13%">120.50</td><td width="13%">1000.00</td><td width="13%">1120.50</td>
<td width="22%">2026-10-20</td></tr>
<tr height="22"><td width="13%">2</td><td width="13%">-</td>
<td width="13%">108.20</td><td width="13%">1012.30</td><td width="13%">1120.50</td>
<td width="22%">2026-10-21</td></tr>
<tr height="22"><td width="13%">3</td><td width="13%">-</td>
<td width="13%">96.10</td><td width="13%">1024.40</td><td width="13%">1120.50</td>
<td width="22%">2026-10-22</td></tr>
"""

func selftest() -> Int32 {
    var failed = 0
    func check(_ ok: Bool, _ name: String) {
        print((ok ? "PASS " : "FAIL ") + name)
        if !ok { failed += 1 }
    }

    let rows = SzuAPI.parseRows(sampleHTML)
    check(rows.count == 3, "解析出 3 行")
    check(rows.first?.date == "2026-10-20", "日期列")
    check(abs((rows.first?.remain ?? 0) - 120.50) < 0.001, "剩余电量列")
    check(abs((rows.first?.used ?? 0) - 1000.00) < 0.001, "已用电列")

    let gbk = GBK.percent("冬筑")
    check(gbk == "%B6%AC%D6%FE", "GBK 百分号编码（冬筑）")

    let snap = Snapshot(date: "2026-10-22", remain: 96.10, dayUse: 12.10, avg: 12.20,
                        avgDays: 2, series: [("10-21", 12.3), ("10-22", 12.1)],
                        fetchedAt: Date(), roomId: "1")
    let warn = warnInfo(snap: snap, cfg: ["warnBelow": 200.0])
    check(warn != nil, "阈值 200 时触发预警")
    check(warn?.sticky == true, "第一次触发是粘住的")
    check(warnInfo(snap: snap, cfg: ["warnBelow": 50.0]) == nil, "阈值 50 时不触发")

    let acked = warnInfo(snap: snap, cfg: ["warnBelow": 200.0, "warnAckDate": "2026-10-22",
                                           "warnAckRemain": 96.10])
    check(acked?.sticky == false, "同一读数确认过就不再粘")

    print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
    return failed == 0 ? 0 : 1
}

// ============================ 入口 ============================

if CommandLine.arguments.contains("--selftest") {
    exit(selftest())
}

let app = NSApplication.shared
let delegate = AppDelegate()
AppDelegate.current = delegate
app.delegate = delegate
app.run()

