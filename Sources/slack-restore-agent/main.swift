import AppKit
import ApplicationServices
import Foundation

setbuf(stdout, nil)
setbuf(stderr, nil)

struct AgentFailure: Error, CustomStringConvertible {
    let description: String
}

enum DisplayTarget: String {
    case leftmost
    case rightmost

    var description: String {
        switch self {
        case .leftmost:
            return "leftmost"
        case .rightmost:
            return "rightmost"
        }
    }

    func selectDisplay(from displays: [Display]) -> Display? {
        switch self {
        case .leftmost:
            return displays.min { first, second in
                if first.bounds.minX == second.bounds.minX {
                    return first.bounds.minY < second.bounds.minY
                }
                return first.bounds.minX < second.bounds.minX
            }
        case .rightmost:
            return displays.max { first, second in
                if first.bounds.minX == second.bounds.minX {
                    return first.bounds.minY < second.bounds.minY
                }
                return first.bounds.minX < second.bounds.minX
            }
        }
    }
}

struct AppRule {
    let displayName: String
    let bundleIdentifier: String
    let appNames: Set<String>
    let target: DisplayTarget
    let ignoredWindowTitles: Set<String>
    let ignoredWindowTitleFragments: Set<String>

    var key: String {
        displayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    func matches(application: NSRunningApplication) -> Bool {
        if application.bundleIdentifier == bundleIdentifier {
            return true
        }
        guard let localizedName = application.localizedName else {
            return false
        }
        return appNames.contains(localizedName)
    }

    func matches(window: VisibleWindow, runningPIDs: Set<pid_t>) -> Bool {
        runningPIDs.contains(window.ownerPID) || appNames.contains(window.ownerName)
    }

    func ignoresWindowTitle(_ title: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ignoredWindowTitles.contains(normalizedTitle)
            || ignoredWindowTitleFragments.contains(where: { normalizedTitle.contains($0) })
    }
}

struct Config {
    var interval: TimeInterval
    var expectedDisplays: Int
    var rules: [AppRule]
    var minWindowWidth: CGFloat
    var minWindowHeight: CGFloat
    var once: Bool
    var verbose: Bool
    var dryRun: Bool
    var promptPermission: Bool
    var logFile: String?
    var maxUptime: TimeInterval

    static func load(arguments: [String], environment: [String: String]) throws -> Config {
        var config = Config(
            interval: environment.double("SLACK_RESTORE_INTERVAL_SECONDS") ?? 2,
            expectedDisplays: environment.int("SLACK_RESTORE_EXPECTED_DISPLAYS") ?? 3,
            rules: Config.defaultRules(environment: environment),
            minWindowWidth: CGFloat(environment.double("SLACK_RESTORE_MIN_WINDOW_WIDTH") ?? 400),
            minWindowHeight: CGFloat(environment.double("SLACK_RESTORE_MIN_WINDOW_HEIGHT") ?? 300),
            once: false,
            verbose: environment.bool("SLACK_RESTORE_VERBOSE"),
            dryRun: environment.bool("SLACK_RESTORE_DRY_RUN"),
            promptPermission: false,
            logFile: environment["SLACK_RESTORE_LOG_FILE"],
            maxUptime: environment.double("SLACK_RESTORE_MAX_UPTIME_SECONDS") ?? 21600
        )

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                printHelp()
                exit(0)
            case "--once":
                config.once = true
            case "--verbose", "-v":
                config.verbose = true
            case "--dry-run":
                config.dryRun = true
            case "--prompt-permission":
                config.promptPermission = true
            case "--log-file":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw AgentFailure(description: "--log-file requires a path")
                }
                config.logFile = arguments[index]
            case "--interval":
                index += 1
                guard index < arguments.count, let value = TimeInterval(arguments[index]), value > 0 else {
                    throw AgentFailure(description: "--interval requires a positive number of seconds")
                }
                config.interval = value
            case "--max-uptime":
                index += 1
                guard index < arguments.count, let value = TimeInterval(arguments[index]), value > 0 else {
                    throw AgentFailure(description: "--max-uptime requires a positive number of seconds")
                }
                config.maxUptime = value
            case "--expected-displays":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw AgentFailure(description: "--expected-displays requires a positive integer")
                }
                config.expectedDisplays = value
            case "--bundle-id":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw AgentFailure(description: "--bundle-id requires a value")
                }
                config.rules[0] = config.rules[0].with(bundleIdentifier: arguments[index])
            case "--app-name":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw AgentFailure(description: "--app-name requires a value")
                }
                config.rules[0] = config.rules[0].with(displayName: arguments[index], appNames: [arguments[index]])
            case "--min-window-width":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                    throw AgentFailure(description: "--min-window-width requires a positive number")
                }
                config.minWindowWidth = CGFloat(value)
            case "--min-window-height":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                    throw AgentFailure(description: "--min-window-height requires a positive number")
                }
                config.minWindowHeight = CGFloat(value)
            default:
                throw AgentFailure(description: "unknown argument: \(argument)")
            }
            index += 1
        }

        return config
    }

    private static func defaultRules(environment: [String: String]) -> [AppRule] {
        let slackName = environment["SLACK_RESTORE_APP_NAME"] ?? "Slack"
        let slackBundleIdentifier = environment["SLACK_RESTORE_BUNDLE_ID"] ?? "com.tinyspeck.slackmacgap"
        let outlookName = environment["OUTLOOK_RESTORE_APP_NAME"] ?? "Microsoft Outlook"
        let outlookBundleIdentifier = environment["OUTLOOK_RESTORE_BUNDLE_ID"] ?? "com.microsoft.Outlook"

        return [
            AppRule(
                displayName: slackName,
                bundleIdentifier: slackBundleIdentifier,
                appNames: Set([slackName, "Slack"]),
                target: .leftmost,
                ignoredWindowTitles: Set(["preferences", "settings", "about slack"]),
                ignoredWindowTitleFragments: Set(["huddle", "junta", "slack call", "call with", "llamada"])
            ),
            AppRule(
                displayName: outlookName,
                bundleIdentifier: outlookBundleIdentifier,
                appNames: Set([outlookName, "Outlook", "Microsoft Outlook"]),
                target: .rightmost,
                ignoredWindowTitles: Set(["preferences", "settings", "about microsoft outlook", "about outlook"]),
                ignoredWindowTitleFragments: Set()
            )
        ]
    }
}

extension AppRule {
    func with(bundleIdentifier: String) -> AppRule {
        AppRule(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            appNames: appNames,
            target: target,
            ignoredWindowTitles: ignoredWindowTitles,
            ignoredWindowTitleFragments: ignoredWindowTitleFragments
        )
    }

    func with(displayName: String, appNames: Set<String>) -> AppRule {
        AppRule(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            appNames: appNames,
            target: target,
            ignoredWindowTitles: ignoredWindowTitles,
            ignoredWindowTitleFragments: ignoredWindowTitleFragments
        )
    }
}

extension Dictionary where Key == String, Value == String {
    func bool(_ key: String) -> Bool {
        guard let value = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }

    func double(_ key: String) -> Double? {
        guard let value = self[key] else {
            return nil
        }
        return Double(value)
    }

    func int(_ key: String) -> Int? {
        guard let value = self[key] else {
            return nil
        }
        return Int(value)
    }
}

struct Display {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let visibleFrame: CGRect
}

struct VisibleWindow {
    let windowNumber: Int
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect

    var area: CGFloat {
        bounds.width * bounds.height
    }

    init?(dictionary: [String: Any]) {
        guard let number = (dictionary[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let ownerPIDValue = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
            return nil
        }

        if let isOnScreen = dictionary[kCGWindowIsOnscreen as String] as? NSNumber, !isOnScreen.boolValue {
            return nil
        }

        self.windowNumber = number
        self.ownerPID = pid_t(ownerPIDValue)
        self.ownerName = dictionary[kCGWindowOwnerName as String] as? String ?? ""
        self.title = dictionary[kCGWindowName as String] as? String ?? ""
        self.layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        self.alpha = (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        self.bounds = bounds
    }
}

struct AXWindowMetadata {
    let element: AXUIElement
    let number: Int?
    let title: String
    let role: String
    let subrole: String
    let minimized: Bool
    let fullScreen: Bool
    let position: CGPoint?
    let size: CGSize?

    var frame: CGRect? {
        guard let position, let size else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    var area: CGFloat {
        guard let frame else {
            return 0
        }
        return frame.width * frame.height
    }

    var isStandardWindow: Bool {
        role == (kAXWindowRole as String) && (subrole.isEmpty || subrole == "AXStandardWindow")
    }

    var isActionable: Bool {
        isStandardWindow && !minimized && !fullScreen
    }

    var skipReason: String? {
        if !isStandardWindow {
            return "not a standard window"
        }
        if minimized {
            return "minimized"
        }
        if fullScreen {
            return "full screen"
        }
        return nil
    }
}

enum AXResolution {
    case found(AXWindowMetadata)
    case skipped(String)
    case missing
}

struct TickStatus {
    let key: String
    let message: String

    static func idle(_ key: String, _ message: String) -> TickStatus {
        TickStatus(key: key, message: message)
    }

    static func important(_ key: String, _ message: String) -> TickStatus {
        TickStatus(key: key, message: message)
    }
}

final class Reporter {
    private var lastKey: String?
    private let verbose: Bool
    private let logFile: String?

    init(verbose: Bool, logFile: String?) {
        self.verbose = verbose
        self.logFile = logFile
    }

    func report(_ status: TickStatus) {
        guard verbose || status.key != lastKey else {
            return
        }
        lastKey = status.key
        write("[\(Self.timestamp())] \(status.message)")
    }

    func write(_ line: String) {
        print(line)
        guard let logFile else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: logFile).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data((line + "\n").utf8)
            if FileManager.default.fileExists(atPath: logFile) {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: logFile))
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: URL(fileURLWithPath: logFile), options: .atomic)
            }
        } catch {
            fputs("slack-restore-agent: could not write log file \(logFile): \(error)\n", stderr)
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

final class WindowRestoreAgent {
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    func tick() -> TickStatus {
        guard isAccessibilityTrusted(prompt: config.promptPermission) else {
            return .important(
                "missing-accessibility",
                "Accessibility permission is missing. Run `bin/slack-restore open-permissions`, then allow Slack Restore Agent in System Settings > Privacy & Security > Accessibility. If it is already enabled, remove it from the list and add the current app bundle again."
            )
        }

        do {
            let displays = try activeDisplays()
            guard displays.count == config.expectedDisplays else {
                return .idle(
                    "display-count-\(displays.count)",
                    "Waiting for exactly \(config.expectedDisplays) displays; found \(displays.count)."
                )
            }

            // macOS has occasionally reported two displays at overlapping bounds (e.g. an
            // external display briefly parked at the main display's origin) for extended
            // stretches after waking or reconfiguring. Moving a window into that bad
            // geometry sends it to the wrong spot and it looks "stuck" there until the
            // system corrects itself on its own, so skip enforcement until bounds sort out.
            if let overlap = firstOverlappingPair(in: displays) {
                return .idle(
                    "display-bounds-overlap",
                    "Display arrangement looks inconsistent (display \(overlap.0.id) and \(overlap.1.id) bounds overlap); waiting for it to settle."
                )
            }

            let statuses = try config.rules.map { rule in
                try enforce(rule: rule, displays: displays)
            }

            return combine(statuses: statuses)
        } catch {
            return .important("error-\(error)", "Error: \(error)")
        }
    }

    private func enforce(rule: AppRule, displays: [Display]) throws -> TickStatus {
        guard let targetDisplay = rule.target.selectDisplay(from: displays) else {
            return .idle("\(rule.key)-no-\(rule.target.rawValue)-display", "No \(rule.target.description) display was available for \(rule.displayName).")
        }

        let runningPIDs = runningProcessIDs(for: rule)
        guard let visibleWindow = visibleMainWindow(for: rule, runningPIDs: runningPIDs) else {
            return .idle("\(rule.key)-no-visible-window", "No visible \(rule.displayName) main window on the current Space.")
        }

        let currentBounds = windowBounds(for: visibleWindow, runningPIDs: runningPIDs)
        guard !isClose(currentBounds, to: targetDisplay.visibleFrame) else {
            return .idle("\(rule.key)-already-\(rule.target.rawValue)", "\(rule.displayName) is already on the \(rule.target.description) display.")
        }

        switch resolveAXWindow(for: visibleWindow, runningPIDs: runningPIDs) {
        case .found(let window):
            if rule.ignoresWindowTitle(window.title) {
                return .idle("\(rule.key)-skip-ignored-title", "Ignoring \(rule.displayName) main window because its title is ignored.")
            }
            return move(window: window, to: targetDisplay.visibleFrame, from: visibleWindow, rule: rule)
        case .skipped(let reason):
            return .idle("\(rule.key)-skip-\(reason)", "Ignoring \(rule.displayName) main window because it is \(reason).")
        case .missing:
            return .important(
                "\(rule.key)-missing-ax-window",
                "\(rule.displayName) is visible but its Accessibility window could not be matched."
            )
        }
    }

    private func windowBounds(for visibleWindow: VisibleWindow, runningPIDs: Set<pid_t>) -> CGRect {
        switch resolveAXWindow(for: visibleWindow, runningPIDs: runningPIDs) {
        case .found(let window):
            return window.frame ?? visibleWindow.bounds
        case .skipped, .missing:
            return visibleWindow.bounds
        }
    }

    private func combine(statuses: [TickStatus]) -> TickStatus {
        TickStatus(
            key: statuses.map(\.key).joined(separator: "|"),
            message: statuses.map(\.message).joined(separator: " ")
        )
    }

    private func move(window: AXWindowMetadata, to targetBounds: CGRect, from visibleWindow: VisibleWindow, rule: AppRule) -> TickStatus {
        if config.dryRun {
            return .important(
                "\(rule.key)-dry-run-\(visibleWindow.windowNumber)",
                "Would move \(rule.displayName) window \(visibleWindow.windowNumber) to the \(rule.target.description) display \(format(rect: targetBounds))."
            )
        }

        if rule.target == .leftmost {
            let stagingBounds = stagingFrame(inside: targetBounds)
            if let status = apply(frame: stagingBounds, to: window, rule: rule, stage: "staging", order: .sizeThenPosition) {
                return status
            }
        }
        if let status = apply(frame: targetBounds, to: window, rule: rule, stage: "target", order: .positionThenSize) {
            return status
        }
        if let status = apply(position: targetBounds.origin, to: window, rule: rule, stage: "final-position") {
            return status
        }

        return .important(
            "\(rule.key)-moved-\(visibleWindow.windowNumber)-\(Int(targetBounds.minX))-\(Int(targetBounds.minY))",
            "Moved \(rule.displayName) window \(visibleWindow.windowNumber) to the \(rule.target.description) display \(format(rect: targetBounds))."
        )
    }

    private func stagingFrame(inside targetBounds: CGRect) -> CGRect {
        let width = min(targetBounds.width, max(config.minWindowWidth, targetBounds.width * 0.45))
        let height = min(targetBounds.height, max(config.minWindowHeight, targetBounds.height * 0.45))
        return CGRect(
            x: targetBounds.minX + ((targetBounds.width - width) / 2),
            y: targetBounds.minY + ((targetBounds.height - height) / 2),
            width: width,
            height: height
        )
    }

    private enum FrameApplyOrder {
        case positionThenSize
        case sizeThenPosition
    }

    private func apply(frame: CGRect, to window: AXWindowMetadata, rule: AppRule, stage: String, order: FrameApplyOrder) -> TickStatus? {
        switch order {
        case .positionThenSize:
            if let status = apply(position: frame.origin, to: window, rule: rule, stage: stage) {
                return status
            }
            return apply(size: frame.size, to: window, rule: rule, stage: stage)
        case .sizeThenPosition:
            if let status = apply(size: frame.size, to: window, rule: rule, stage: stage) {
                return status
            }
            return apply(position: frame.origin, to: window, rule: rule, stage: stage)
        }
    }

    private func apply(position: CGPoint, to window: AXWindowMetadata, rule: AppRule, stage: String) -> TickStatus? {
        var position = position
        guard let positionValue = AXValueCreate(.cgPoint, &position) else {
            return .important("ax-value-create-failed", "Could not create Accessibility geometry values.")
        }

        let result = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
        guard result == .success else {
            return .important(
                "\(rule.key)-move-position-failed-\(stage)-\(result.rawValue)",
                "Could not move \(rule.displayName) window during \(stage): AX position update failed with \(result)."
            )
        }
        return nil
    }

    private func apply(size: CGSize, to window: AXWindowMetadata, rule: AppRule, stage: String) -> TickStatus? {
        var size = size
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            return .important("ax-value-create-failed", "Could not create Accessibility geometry values.")
        }

        let result = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
        guard result == .success else {
            return .important(
                "\(rule.key)-move-size-failed-\(stage)-\(result.rawValue)",
                "Could not resize \(rule.displayName) window during \(stage): AX size update failed with \(result)."
            )
        }
        return nil
    }

    private func firstOverlappingPair(in displays: [Display]) -> (Display, Display)? {
        for i in displays.indices {
            for j in displays.indices where j > i {
                if displays[i].bounds.intersects(displays[j].bounds) {
                    return (displays[i], displays[j])
                }
            }
        }
        return nil
    }

    private func activeDisplays() throws -> [Display] {
        var count: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &count)
        guard countResult == .success else {
            throw AgentFailure(description: "CGGetActiveDisplayList failed with \(countResult)")
        }

        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        let listResult = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(count, buffer.baseAddress, &count)
        }
        guard listResult == .success else {
            throw AgentFailure(description: "CGGetActiveDisplayList failed with \(listResult)")
        }

        return displayIDs.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            return Display(id: id, bounds: bounds, visibleFrame: visibleFrame(forDisplay: id, bounds: bounds))
        }
    }

    // CGDisplayBounds is the raw panel resolution; each display reserves space for its
    // own menu bar (and the Dock, if docked there). Targeting the raw bounds means the
    // window server clamps the applied size below what we asked for, `isClose` never
    // matches, and the agent re-moves the window every poll forever. NSScreen.visibleFrame
    // gives the actually-usable area, but in AppKit's bottom-left-origin coordinate space,
    // so it has to be flipped into Quartz's top-left-origin space to compare against AX/CG geometry.
    private func visibleFrame(forDisplay id: CGDirectDisplayID, bounds: CGRect) -> CGRect {
        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else {
            return bounds
        }
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDirectDisplayID(screenNumber.uint32Value) == id else {
                continue
            }
            let visible = screen.visibleFrame
            let flippedY = primaryScreenHeight - (visible.origin.y + visible.height)
            return CGRect(x: visible.origin.x, y: flippedY, width: visible.width, height: visible.height)
        }
        return bounds
    }

    private func runningProcessIDs(for rule: AppRule) -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.compactMap { application in
            rule.matches(application: application) ? application.processIdentifier : nil
        })
    }

    private func visibleMainWindow(for rule: AppRule, runningPIDs: Set<pid_t>) -> VisibleWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let dictionaries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates = dictionaries.compactMap(VisibleWindow.init(dictionary:))
            .filter { window in
                return rule.matches(window: window, runningPIDs: runningPIDs)
                    && window.layer == 0
                    && window.alpha > 0
                    && window.bounds.width >= config.minWindowWidth
                    && window.bounds.height >= config.minWindowHeight
                    && !rule.ignoresWindowTitle(window.title)
            }
            .sorted { $0.area > $1.area }

        // CGWindowName is blank without Screen Recording permission, so the CG-title
        // check above can miss a Huddle window; cross-check against the Accessibility
        // title (needs only the Accessibility permission we already require) before
        // picking the largest remaining candidate.
        for candidate in candidates {
            if let axTitle = resolvedAXTitle(for: candidate, runningPIDs: runningPIDs), rule.ignoresWindowTitle(axTitle) {
                continue
            }
            return candidate
        }
        return candidates.first
    }

    private func resolvedAXTitle(for visibleWindow: VisibleWindow, runningPIDs: Set<pid_t>) -> String? {
        switch resolveAXWindow(for: visibleWindow, runningPIDs: runningPIDs) {
        case .found(let window):
            return window.title
        case .skipped, .missing:
            return nil
        }
    }

    private func resolveAXWindow(for visibleWindow: VisibleWindow, runningPIDs: Set<pid_t>) -> AXResolution {
        let processIDs = Array(Set([visibleWindow.ownerPID]).union(runningPIDs)).filter { $0 > 0 }
        var allWindows: [AXWindowMetadata] = []

        for processID in processIDs {
            let application = AXUIElementCreateApplication(processID)
            let windows = copyAXWindows(from: application)
            let metadata = windows.map(AXWindowMetadata.init(element:))
            allWindows.append(contentsOf: metadata)

            if let exact = metadata.first(where: { $0.number == visibleWindow.windowNumber }) {
                if let reason = exact.skipReason {
                    return .skipped(reason)
                }
                return .found(exact)
            }
        }

        let actionableWindows = allWindows.filter(\.isActionable)
        if let byTitle = actionableWindows
            .filter({ !$0.title.isEmpty && $0.title == visibleWindow.title })
            .max(by: { $0.area < $1.area }) {
            return .found(byTitle)
        }

        if let closest = closestWindow(to: visibleWindow.bounds, in: actionableWindows) {
            return .found(closest)
        }

        if actionableWindows.count == 1, let onlyWindow = actionableWindows.first {
            return .found(onlyWindow)
        }

        return .missing
    }

    private func closestWindow(to target: CGRect, in windows: [AXWindowMetadata]) -> AXWindowMetadata? {
        let scored = windows.compactMap { window -> (window: AXWindowMetadata, score: CGFloat)? in
            guard let frame = window.frame else {
                return nil
            }

            let centerDistance = hypot(frame.midX - target.midX, frame.midY - target.midY)
            let sizeDifference = abs(frame.width - target.width) + abs(frame.height - target.height)
            return (window, centerDistance + sizeDifference)
        }

        guard let best = scored.min(by: { $0.score < $1.score }) else {
            return nil
        }

        // Avoid matching an unrelated app dialog when geometry is nowhere near
        // the visible Quartz window selected as the main-window candidate.
        return best.score <= 600 ? best.window : nil
    }
}

extension AXWindowMetadata {
    init(element: AXUIElement) {
        self.element = element
        self.number = copyAXInt(element, attribute: "AXWindowNumber" as CFString)
        self.title = copyAXString(element, attribute: kAXTitleAttribute as CFString) ?? ""
        self.role = copyAXString(element, attribute: kAXRoleAttribute as CFString) ?? ""
        self.subrole = copyAXString(element, attribute: kAXSubroleAttribute as CFString) ?? ""
        self.minimized = copyAXBool(element, attribute: kAXMinimizedAttribute as CFString) ?? false
        self.fullScreen = copyAXBool(element, attribute: "AXFullScreen" as CFString) ?? false
        self.position = copyAXPoint(element, attribute: kAXPositionAttribute as CFString)
        self.size = copyAXSize(element, attribute: kAXSizeAttribute as CFString)
    }
}

private func copyAXWindows(from application: AXUIElement) -> [AXUIElement] {
    guard let value = copyAXAttribute(application, attribute: kAXWindowsAttribute as CFString),
          let windows = value as? [AXUIElement] else {
        return []
    }
    return windows
}

private func copyAXAttribute(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success else {
        return nil
    }
    return value
}

private func copyAXString(_ element: AXUIElement, attribute: CFString) -> String? {
    copyAXAttribute(element, attribute: attribute) as? String
}

private func copyAXBool(_ element: AXUIElement, attribute: CFString) -> Bool? {
    if let value = copyAXAttribute(element, attribute: attribute) as? Bool {
        return value
    }
    return (copyAXAttribute(element, attribute: attribute) as? NSNumber)?.boolValue
}

private func copyAXInt(_ element: AXUIElement, attribute: CFString) -> Int? {
    (copyAXAttribute(element, attribute: attribute) as? NSNumber)?.intValue
}

private func copyAXPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
    guard let rawValue = copyAXAttribute(element, attribute: attribute) else {
        return nil
    }

    guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
        return nil
    }

    let value = rawValue as! AXValue
    guard AXValueGetType(value) == .cgPoint else {
        return nil
    }

    var point = CGPoint.zero
    guard AXValueGetValue(value, .cgPoint, &point) else {
        return nil
    }
    return point
}

private func copyAXSize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
    guard let rawValue = copyAXAttribute(element, attribute: attribute) else {
        return nil
    }

    guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
        return nil
    }

    let value = rawValue as! AXValue
    guard AXValueGetType(value) == .cgSize else {
        return nil
    }

    var size = CGSize.zero
    guard AXValueGetValue(value, .cgSize, &size) else {
        return nil
    }
    return size
}

private func isAccessibilityTrusted(prompt: Bool) -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

private func center(of rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
}

// The window server can clamp an applied size below what we asked for (e.g. a display's
// own menu bar reserving space we didn't account for), so a window sitting at the correct
// position but slightly smaller than the target must still count as "in place" - otherwise
// the agent re-applies the same unreachable target forever, visibly bouncing the window.
private func isClose(_ first: CGRect, to second: CGRect, tolerance: CGFloat = 8, maxShrink: CGFloat = 100) -> Bool {
    // A per-display menu bar can push the window's top edge down (and shrink its height to
    // match) even when we asked for the full display bounds - that shift isn't a positioning
    // failure, so minY tolerates being pushed down by up to maxShrink, not just +-tolerance.
    let topInset = first.minY - second.minY
    guard abs(first.minX - second.minX) <= tolerance, topInset >= -tolerance, topInset <= maxShrink else {
        return false
    }
    let widthDeficit = second.width - first.width
    let heightDeficit = second.height - first.height
    return widthDeficit >= -tolerance && widthDeficit <= maxShrink
        && heightDeficit >= -tolerance && heightDeficit <= maxShrink
}

private func format(rect: CGRect) -> String {
    "x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))"
}

private func printHelp() {
    print("""
    slack-restore-agent

    Watches configured apps and moves their visible main windows to assigned displays when exactly three displays are connected.

    Default rules:
      Slack             -> leftmost display
      Microsoft Outlook -> rightmost display

    Options:
      --once                         Run one poll and exit.
      --interval SECONDS             Poll interval. Default: 2.
      --max-uptime SECONDS           Exit (for launchd to relaunch) after running this long. Default: 21600 (6h).
      --expected-displays NUMBER     Required active display count. Default: 3.
      --bundle-id BUNDLE_ID          Override Slack bundle id. Default: com.tinyspeck.slackmacgap.
      --app-name NAME                Override Slack app name. Default: Slack.
      --min-window-width POINTS      Minimum candidate window width. Default: 400.
      --min-window-height POINTS     Minimum candidate window height. Default: 300.
      --dry-run                      Log what would be moved without moving it.
      --prompt-permission            Ask macOS to show the Accessibility permission prompt.
      --log-file PATH                Also append status messages to a log file.
      --verbose                      Log every state change and poll result.
      --help                         Show this help.

    Environment variables:
      SLACK_RESTORE_INTERVAL_SECONDS
      SLACK_RESTORE_MAX_UPTIME_SECONDS
      SLACK_RESTORE_EXPECTED_DISPLAYS
      SLACK_RESTORE_BUNDLE_ID
      SLACK_RESTORE_APP_NAME
      OUTLOOK_RESTORE_BUNDLE_ID
      OUTLOOK_RESTORE_APP_NAME
      SLACK_RESTORE_MIN_WINDOW_WIDTH
      SLACK_RESTORE_MIN_WINDOW_HEIGHT
      SLACK_RESTORE_DRY_RUN
      SLACK_RESTORE_VERBOSE
      SLACK_RESTORE_LOG_FILE
    """)
}

private func main() throws {
    let config = try Config.load(
        arguments: Array(CommandLine.arguments.dropFirst()),
        environment: ProcessInfo.processInfo.environment
    )
    let agent = WindowRestoreAgent(config: config)
    let reporter = Reporter(verbose: config.verbose, logFile: config.logFile)
    let startedAt = Date()

    while true {
        reporter.report(agent.tick())
        if config.once {
            break
        }

        // CGGetActiveDisplayList/CGDisplayBounds have been observed to return stale
        // geometry for a process that has lived through many monitor connect/disconnect
        // cycles, even though a freshly launched process reads the same live state
        // correctly. Periodically exiting lets launchd's KeepAlive relaunch us with a
        // fresh WindowServer connection before that staleness can cause a bad move.
        let uptime = Date().timeIntervalSince(startedAt)
        if uptime >= config.maxUptime {
            reporter.write("[\(ISO8601DateFormatter().string(from: Date()))] Restarting after \(Int(uptime))s uptime to avoid stale display-server state.")
            break
        }

        Thread.sleep(forTimeInterval: config.interval)
    }
}

do {
    try main()
} catch {
    fputs("slack-restore-agent: \(error)\n", stderr)
    exit(1)
}
