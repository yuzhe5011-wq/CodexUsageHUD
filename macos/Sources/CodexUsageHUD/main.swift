import AppKit
import Darwin
import Foundation

private let refreshInterval: TimeInterval = 120
private let rpcTimeout: TimeInterval = 12

// Keep the file in place: unlinking it would allow another process to lock a new inode.
private final class InstanceLock {
    private let descriptor: Int32

    init?(url: URL) throws {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw HUDError.message("无法打开单实例锁。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw HUDError.message("无法获取单实例锁。")
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

private struct UsageWindow {
    let remaining: Int?
    let resetAt: Date?
}

private struct UsageData {
    let fiveHour: UsageWindow
    let weekly: UsageWindow
    let availableCredits: Int?
    let nextCreditExpiry: Date?
    let updatedAt: Date
}

private enum HUDError: LocalizedError {
    case chatGPTMissing
    case codexConnectionFailed
    case message(String)

    var errorDescription: String? {
        switch self {
        case .chatGPTMissing:
            return "未找到 ChatGPT macOS 客户端，请先安装并登录 ChatGPT。"
        case .codexConnectionFailed:
            return "无法连接 Codex，请确认 ChatGPT macOS 客户端已经登录。"
        case .message(let text): return text
        }
    }
}

private func userFacingError(_ error: Error) -> HUDError {
    if let hudError = error as? HUDError {
        switch hudError {
        case .chatGPTMissing: return .chatGPTMissing
        case .codexConnectionFailed, .message: break
        }
    }
    return .codexConnectionFailed
}

private func nestedValue(_ object: Any?, paths: [String]) -> Any? {
    for path in paths {
        var current = object
        var found = true
        for segment in path.split(separator: ".").map(String.init) {
            guard let dictionary = current as? [String: Any], let value = dictionary[segment] else {
                found = false
                break
            }
            current = value
        }
        if found, let current, !(current is NSNull) { return current }
    }
    return nil
}

private func numberValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let text = value as? String { return Double(text) }
    return nil
}

private func dateValue(_ value: Any?) -> Date? {
    if let number = numberValue(value) {
        let seconds = number > 100_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }
    guard let text = value as? String, !text.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

private func durationMinutes(_ window: Any?) -> Int? {
    guard let value = nestedValue(window, paths: [
        "window_duration_mins", "windowDurationMins",
        "window_duration_minutes", "windowDurationMinutes"
    ]) else { return nil }
    return numberValue(value).map { Int($0) }
}

private func windowSummary(_ window: Any?) -> UsageWindow {
    guard window != nil else { return UsageWindow(remaining: nil, resetAt: nil) }
    let used = numberValue(nestedValue(window, paths: ["used_percent", "usedPercent", "percent_used"]))
    var remaining = numberValue(nestedValue(window, paths: ["remaining_percent", "remainingPercent", "percent_remaining"]))
    if remaining == nil, let used { remaining = 100 - used }
    let normalized = remaining.map { max(0, min(100, Int($0.rounded()))) }
    let reset = nestedValue(window, paths: ["reset_at", "resetAt", "resets_at", "resetsAt"])
    return UsageWindow(remaining: normalized, resetAt: dateValue(reset))
}

private func parseUsage(_ response: [String: Any]) -> UsageData {
    let primary = nestedValue(response, paths: [
        "rateLimits.primary", "rate_limits.primary", "rateLimit.primary", "primary"
    ])
    let secondary = nestedValue(response, paths: [
        "rateLimits.secondary", "rate_limits.secondary", "rateLimit.secondary", "secondary"
    ])
    let primaryDuration = durationMinutes(primary)
    let secondaryDuration = durationMinutes(secondary)

    let fiveHour: Any?
    if primaryDuration == 300 { fiveHour = primary }
    else if secondaryDuration == 300 { fiveHour = secondary }
    else if primaryDuration == nil, secondaryDuration == nil { fiveHour = primary }
    else { fiveHour = nil }

    let weekly: Any?
    if primaryDuration == 10_080 { weekly = primary }
    else if secondaryDuration == 10_080 { weekly = secondary }
    else if primaryDuration == nil, secondaryDuration == nil { weekly = secondary }
    else { weekly = nil }

    let resetCredits = nestedValue(response, paths: [
        "rateLimitResetCredits", "rate_limit_reset_credits",
        "rateLimits.rateLimitResetCredits", "resetCredits"
    ])
    let rawCredits = nestedValue(resetCredits, paths: [
        "credits", "items", "expirations", "expirationDetails", "available"
    ]) as? [Any] ?? []
    let available = rawCredits.filter { item in
        guard let dictionary = item as? [String: Any] else { return false }
        let status = nestedValue(dictionary, paths: ["status", "state"]) as? String
        return status == nil || status == "available"
    }
    var count = numberValue(nestedValue(resetCredits, paths: ["available_count", "availableCount"])).map(Int.init)
    if count == nil, !available.isEmpty { count = available.count }

    var expirations = available.compactMap { item -> Date? in
        if let dictionary = item as? [String: Any] {
            return dateValue(nestedValue(dictionary, paths: ["expires_at", "expiresAt", "expiresOn", "expiration"]))
        }
        return dateValue(item)
    }
    if let direct = dateValue(nestedValue(resetCredits, paths: ["nextExpiresAt", "next_expires_at", "earliestExpiresAt"])) {
        expirations.append(direct)
    }

    return UsageData(
        fiveHour: windowSummary(fiveHour),
        weekly: windowSummary(weekly),
        availableCredits: resetCredits == nil ? nil : count,
        nextCreditExpiry: expirations.sorted().first,
        updatedAt: Date()
    )
}

private func hasUsableUsage(_ data: UsageData) -> Bool {
    return data.fiveHour.remaining != nil || data.fiveHour.resetAt != nil ||
        data.weekly.remaining != nil || data.weekly.resetAt != nil ||
        data.availableCredits != nil || data.nextCreditExpiry != nil
}

private final class AppServerClient {
    private let condition = NSCondition()
    private var responses: [Int: [String: Any]] = [:]
    private var outputBuffer = Data()
    private var ended = false

    func readUsage() throws -> UsageData {
        let process = Process()
        process.executableURL = try resolveCodexCommand()
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            self?.condition.lock()
            self?.ended = true
            self?.condition.broadcast()
            self?.condition.unlock()
        }

        do { try process.run() }
        catch { throw HUDError.message("无法启动 Codex CLI：\(error.localizedDescription)") }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        try send([
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "codex-usage-hud", "version": "2.0.1"]]
        ], to: input.fileHandleForWriting)
        _ = try waitForResponse(id: 1)
        try send(["method": "initialized", "params": [:] as [String: Any]], to: input.fileHandleForWriting)
        try send(["id": 2, "method": "account/rateLimits/read", "params": [:] as [String: Any]], to: input.fileHandleForWriting)
        let message = try waitForResponse(id: 2)
        if let error = message["error"] as? [String: Any] {
            throw HUDError.message("Codex app-server 请求失败：\(error["message"] as? String ?? "未知错误")")
        }
        guard let result = message["result"] as? [String: Any] else {
            throw HUDError.message("Codex app-server 返回了没有 result 的响应。")
        }
        let data = parseUsage(result)
        guard hasUsableUsage(data) else {
            throw HUDError.message("Codex app-server 返回了空的用量数据。")
        }
        return data
    }

    private func resolveCodexCommand() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let systemChatGPT = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        let userChatGPT = home.appendingPathComponent("Applications/ChatGPT.app", isDirectory: true)
        var candidates: [String] = []
        if let override = environment["CODEX_USAGE_HUD_CODEX"], !override.isEmpty {
            candidates.append((override as NSString).expandingTildeInPath)
        }
        candidates += [
            systemChatGPT.appendingPathComponent("Contents/Resources/codex").path,
            systemChatGPT.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path,
            userChatGPT.appendingPathComponent("Contents/Resources/codex").path,
            userChatGPT.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path
        ]
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(directory)/codex")
        }

        for path in candidates where isUsableCodex(atPath: path) {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        let chatGPTInstalled = manager.fileExists(atPath: systemChatGPT.path) ||
            manager.fileExists(atPath: userChatGPT.path)
        if !chatGPTInstalled {
            throw HUDError.chatGPTMissing
        }
        throw HUDError.codexConnectionFailed
    }

    private func isUsableCodex(atPath path: String) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path), manager.isExecutableFile(atPath: path) else { return false }
        let executable = URL(fileURLWithPath: path).standardizedFileURL
        return commandSucceeds(executable, arguments: ["--version"]) &&
            commandSucceeds(executable, arguments: ["app-server", "--help"])
    }

    private func commandSucceeds(_ executable: URL, arguments: [String]) -> Bool {
        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() }
        catch { return false }

        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            return false
        }
        return process.terminationStatus == 0
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        if data.isEmpty { ended = true; condition.broadcast(); return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let dictionary = object as? [String: Any],
                  let id = numberValue(dictionary["id"]).map(Int.init) else { continue }
            responses[id] = dictionary
            condition.broadcast()
        }
    }

    private func waitForResponse(id: Int) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(rpcTimeout)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil, !ended {
            if !condition.wait(until: deadline) { break }
        }
        if let response = responses.removeValue(forKey: id) { return response }
        if ended { throw HUDError.message("Codex app-server 在返回数据前已退出。") }
        throw HUDError.message("等待 Codex app-server 响应超时。")
    }
}

private func countdown(_ date: Date?) -> String {
    guard let date else { return "暂无时间" }
    let seconds = Int(date.timeIntervalSinceNow)
    if seconds <= 0 { return "即将刷新" }
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3600
    let minutes = (seconds % 3600) / 60
    if days > 0 { return "\(days)天 \(hours)小时后" }
    if hours > 0 { return "\(hours)小时 \(minutes)分钟后" }
    return "\(max(1, minutes))分钟后"
}

private final class HUDView: NSView {
    var usage: UsageData? { didSet { needsDisplay = true } }
    var errorText: String? { didSet { needsDisplay = true } }
    var expanded = false { didSet { needsDisplay = true; updateTrackingAreas() } }
    var onHoverChanged: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var dragOrigin: NSPoint?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        dragOrigin = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = dragOrigin else { return }
        let current = NSEvent.mouseLocation
        onDrag?(NSPoint(x: current.x - previous.x, y: current.y - previous.y))
        dragOrigin = current
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        onDragEnded?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if expanded { drawDetails() } else { drawCompact() }
    }

    private func drawCompact() {
        let fiveHourRemaining = usage?.fiveHour.remaining
        let weeklyRemaining = usage?.weekly.remaining
        let first = fiveHourRemaining.map { "\($0)%" } ?? "--%"
        let second = weeklyRemaining.map { "\($0)%" } ?? "--%"
        drawText(first, rect: NSRect(x: 0, y: 11, width: 76, height: 25), size: 17, weight: .semibold,
                 color: meterColor(fiveHourRemaining), alignment: .center)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        fillRect(NSRect(x: 76.5, y: 11, width: 1, height: 24))
        drawText(second, rect: NSRect(x: 78, y: 11, width: 76, height: 25), size: 17, weight: .semibold,
                 color: meterColor(weeklyRemaining), alignment: .center)
        drawCompactBar(remaining: fiveHourRemaining, x: 12)
        drawCompactBar(remaining: weeklyRemaining, x: 90)
    }

    private func drawCompactBar(remaining: Int?, x: CGFloat) {
        guard let remaining else { return }
        meterColor(remaining).withAlphaComponent(0.85).setFill()
        fillRect(NSRect(x: x, y: 38, width: 52 * CGFloat(remaining) / 100, height: 2))
    }

    private func drawDetails() {
        let statusColor = errorText == nil ? NSColor.systemGreen : NSColor.systemRed
        statusColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 10, y: 33, width: 6, height: 6)).fill()
        drawText("Codex", rect: NSRect(x: 22, y: 18, width: 64, height: 19), size: 13, weight: .semibold)
        drawText(errorText == nil ? "APP-SERVER" : "刷新失败", rect: NSRect(x: 22, y: 38, width: 70, height: 15), size: 10, weight: .medium, color: .secondaryLabelColor)
        separator(x: 94)
        drawMeter(title: "5 小时", window: usage?.fiveHour, x: 106, width: 96)
        drawMeter(title: "每周额度", window: usage?.weekly, x: 214, width: 104)
        separator(x: 330)
        drawText("可用重置卡", rect: NSRect(x: 342, y: 16, width: 82, height: 15), size: 11, weight: .semibold, color: .secondaryLabelColor)
        let creditCount = usage?.availableCredits
        let credits = creditCount.map(String.init) ?? "--"
        drawText("\(credits) 张", rect: NSRect(x: 342, y: 32, width: 82, height: 26), size: 19, weight: .semibold)
        separator(x: 430)
        drawText("最近到期", rect: NSRect(x: 442, y: 14, width: 105, height: 15), size: 11, weight: .semibold, color: .secondaryLabelColor)
        let expiry: String
        let expiryDetail: String
        if let creditCount {
            if creditCount > 0, let nextCreditExpiry = usage?.nextCreditExpiry {
                expiry = Self.shortDate.string(from: nextCreditExpiry)
                expiryDetail = countdown(nextCreditExpiry)
            } else if creditCount > 0 {
                expiry = "未提供"
                expiryDetail = "当前 Codex 未返回到期时间"
            } else {
                expiry = "—"
                expiryDetail = "没有可用卡"
            }
        } else {
            expiry = "不可用"
            expiryDetail = "当前 Codex 未返回重置卡数据"
        }
        drawText(expiry, rect: NSRect(x: 442, y: 30, width: 105, height: 20), size: 15, weight: .semibold)
        drawText(expiryDetail, rect: NSRect(x: 442, y: 50, width: 105, height: 14), size: 10, weight: .medium, color: .secondaryLabelColor)
        drawText("↻", rect: NSRect(x: 550, y: 21, width: 24, height: 24), size: 17, color: .secondaryLabelColor, alignment: .center)
        let updated = usage.map { Self.time.string(from: $0.updatedAt) } ?? "--:--"
        drawText(updated, rect: NSRect(x: 548, y: 47, width: 28, height: 12), size: 9, weight: .semibold, color: .secondaryLabelColor, alignment: .center)
    }

    private func drawMeter(title: String, window: UsageWindow?, x: CGFloat, width: CGFloat) {
        drawText(title, rect: NSRect(x: x, y: 13, width: width, height: 15), size: 11, weight: .semibold, color: .secondaryLabelColor)
        let value = window?.remaining
        drawText(value.map { "\($0)%" } ?? "--%", rect: NSRect(x: x, y: 11, width: width, height: 23), size: 17,
                 weight: .semibold, color: meterColor(value), alignment: .right)
        NSColor.separatorColor.withAlphaComponent(0.3).setFill()
        fillRect(NSRect(x: x, y: 38, width: width, height: 3))
        if let value {
            meterColor(value).setFill()
            fillRect(NSRect(x: x, y: 38, width: width * CGFloat(value) / 100, height: 3))
        }
        drawText("重置：\(countdown(window?.resetAt))", rect: NSRect(x: x, y: 46, width: width, height: 14), size: 10, weight: .medium, color: .secondaryLabelColor)
    }

    private func meterColor(_ value: Int?) -> NSColor {
        guard let value else { return .secondaryLabelColor }
        if value <= 10 { return .systemRed }
        if value <= 25 { return .systemOrange }
        return .systemBlue
    }

    private func separator(x: CGFloat) {
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        fillRect(NSRect(x: x, y: 12, width: 1, height: 52))
    }

    private func fillRect(_ rect: NSRect) {
        NSBezierPath(rect: rect).fill()
    }

    private func drawText(_ text: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                          color: NSColor = .labelColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }

    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd  HH:mm"
        return formatter
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private final class HUDController {
    private let compactSize = NSSize(width: 154, height: 46)
    private let detailSize = NSSize(width: 580, height: 76)
    private let panel: NSPanel
    private let effectView: NSVisualEffectView
    private let hudView: HUDView
    private var compactOrigin = NSPoint.zero
    private var expanded = false
    private var refreshing = false
    private var hasPresentedStartupError = false
    private var timer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: compactSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: compactSize))
        hudView = HUDView(frame: effectView.bounds)
        configurePanel()
        configureEvents()
    }

    func show() {
        if compactOrigin == .zero, let screen = NSScreen.main {
            compactOrigin = NSPoint(x: screen.visibleFrame.midX - compactSize.width / 2,
                                    y: screen.visibleFrame.maxY - compactSize.height - 6)
        }
        clampAnchor()
        applyLayout()
        panel.orderFrontRegardless()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func toggleVisibility() -> Bool {
        if panel.isVisible { panel.orderOut(nil); return false }
        clampAnchor()
        applyLayout()
        panel.orderFrontRegardless()
        return true
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let client = AppServerClient()
                let data = try client.readUsage()
                DispatchQueue.main.async {
                    self?.hudView.usage = data
                    self?.hudView.errorText = nil
                    self?.refreshing = false
                }
            } catch {
                let message = userFacingError(error).localizedDescription
                DispatchQueue.main.async {
                    self?.hudView.errorText = message
                    self?.presentStartupError(message)
                    self?.refreshing = false
                }
            }
        }
    }

    private func presentStartupError(_ message: String) {
        guard !hasPresentedStartupError else { return }
        hasPresentedStartupError = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func configurePanel() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.6
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        hudView.autoresizingMask = [.width, .height]
        effectView.addSubview(hudView)
        panel.contentView = effectView
    }

    private func configureEvents() {
        hudView.onHoverChanged = { [weak self] hovered in self?.setExpanded(hovered) }
        hudView.onDoubleClick = { [weak self] in self?.refresh() }
        hudView.onDrag = { [weak self] delta in
            guard let self else { return }
            compactOrigin.x += delta.x
            compactOrigin.y += delta.y
            applyLayout()
        }
        hudView.onDragEnded = { [weak self] in
            self?.clampAnchor()
            self?.applyLayout()
        }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        clampAnchor()
        applyLayout()
    }

    private func activeScreen() -> NSScreen? {
        let center = NSPoint(x: compactOrigin.x + compactSize.width / 2, y: compactOrigin.y + compactSize.height / 2)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func clampAnchor() {
        guard let frame = activeScreen()?.visibleFrame else { return }
        compactOrigin.x = max(frame.minX, min(compactOrigin.x, frame.maxX - compactSize.width))
        compactOrigin.y = max(frame.minY, min(compactOrigin.y, frame.maxY - compactSize.height))
    }

    private func applyLayout() {
        guard let frame = activeScreen()?.visibleFrame else { return }
        let size = expanded ? detailSize : compactSize
        var origin = compactOrigin
        if expanded {
            origin.x += (compactSize.width - detailSize.width) / 2
            origin.y += compactSize.height - detailSize.height
            origin.x = max(frame.minX, min(origin.x, frame.maxX - detailSize.width))
            origin.y = max(frame.minY, min(origin.y, frame.maxY - detailSize.height))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        effectView.frame = NSRect(origin: .zero, size: size)
        effectView.layer?.cornerRadius = expanded ? 17 : 18
        hudView.frame = effectView.bounds
        hudView.expanded = expanded
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: HUDController?
    private var statusItem: NSStatusItem?
    private var visibilityItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = HUDController()
        self.controller = controller
        configureStatusItem()
        controller.show()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeStatusItemImage()
        item.button?.toolTip = "Codex 用量"
        let menu = NSMenu()
        menu.addItem(withTitle: "立即刷新", action: #selector(refresh), keyEquivalent: "r").target = self
        let visibility = menu.addItem(withTitle: "隐藏悬浮条", action: #selector(toggleVisibility), keyEquivalent: "h")
        visibility.target = self
        visibilityItem = visibility
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    private func makeStatusItemImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let outline = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5),
                                       xRadius: 4, yRadius: 4)
            outline.lineWidth = 1.5
            outline.stroke()

            let topMeter = NSBezierPath()
            topMeter.move(to: NSPoint(x: 5, y: 10.75))
            topMeter.line(to: NSPoint(x: 13, y: 10.75))
            topMeter.lineWidth = 2
            topMeter.lineCapStyle = .round
            topMeter.stroke()

            let bottomMeter = NSBezierPath()
            bottomMeter.move(to: NSPoint(x: 5, y: 6.75))
            bottomMeter.line(to: NSPoint(x: 10.5, y: 6.75))
            bottomMeter.lineWidth = 2
            bottomMeter.lineCapStyle = .round
            bottomMeter.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex 用量"
        return image
    }

    @objc private func refresh() { controller?.refresh() }

    @objc private func toggleVisibility() {
        let visible = controller?.toggleVisibility() ?? false
        visibilityItem?.title = visible ? "隐藏悬浮条" : "显示悬浮条"
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private func runSelfTest() -> Int32 {
    let response: [String: Any] = [
        "rateLimits": [
            "primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970],
            "secondary": ["usedPercent": 6, "windowDurationMins": 10_080, "resetsAt": Date().addingTimeInterval(604_800).timeIntervalSince1970]
        ],
        "rateLimitResetCredits": ["availableCount": 3]
    ]
    let data = parseUsage(response)
    guard data.fiveHour.remaining == 75, data.weekly.remaining == 94, data.availableCredits == 3,
          !countdown(Date().addingTimeInterval(172_800)).contains("即将刷新") else {
        fputs("FAIL: parser self-test\n", stderr)
        return 1
    }
    do {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var first = try InstanceLock(url: url)
        guard first != nil, try InstanceLock(url: url) == nil else { return 1 }
        first = nil
        guard let reacquired = try InstanceLock(url: url) else { return 1 }
        withExtendedLifetime(reacquired) {}
        print("PASS: single-instance lock and release")
    } catch {
        fputs("FAIL: single-instance lock: \(error)\n", stderr)
        return 1
    }
    print("PASS: parser self-test")
    return 0
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTest())
}

if CommandLine.arguments.contains("--connection-test") {
    do {
        let client = AppServerClient()
        let data = try client.readUsage()
        print("PASS: Codex app-server connection (weekly: \(data.weekly.remaining.map { "\($0)%" } ?? "--%"))")
        exit(0)
    } catch {
        fputs("FAIL: \(userFacingError(error).localizedDescription)\n", stderr)
        exit(1)
    }
}

// Application Support is shared by all copies of this app for the current user.
private let instanceLock: InstanceLock
do {
    let directory = try FileManager.default.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("CodexUsageHUD", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let lock = try InstanceLock(url: directory.appendingPathComponent("instance.lock")) else {
        print("Codex Usage HUD is already running.")
        exit(0)
    }
    instanceLock = lock
} catch {
    fputs("Codex Usage HUD: \(error.localizedDescription)\n", stderr)
    exit(1)
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
withExtendedLifetime(instanceLock) { application.run() }
