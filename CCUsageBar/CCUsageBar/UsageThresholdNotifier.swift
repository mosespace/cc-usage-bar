import AppKit
import Foundation
import UserNotifications

final class UsageThresholdNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UsageThresholdNotifier()

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let thresholds = [60, 80, 100]
    private let statePrefix = "UsageThresholdNotifier"
    private var authorizationRequestStarted = false

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        guard !authorizationRequestStarted else { return }
        authorizationRequestStarted = true

        let center = center
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func evaluate(snapshot: UsageSnapshot, provider: Provider) {
        for metric in snapshot.metrics where metric.direction == .used {
            evaluate(metric: metric, snapshot: snapshot, provider: provider)
        }
    }

    private func evaluate(metric: UsageMetric, snapshot: UsageSnapshot, provider: Provider) {
        guard let percent = metric.percent else { return }

        let windowIdentifier = metric.resetIdentifier ?? fallbackWindowIdentifier(for: snapshot.capturedAt)
        let baseKey = "\(statePrefix).\(provider.id).\(metric.id)"
        let windowKey = "\(baseKey).window"
        let lastPercentKey = "\(baseKey).lastPercent"
        let notifiedThresholdsKey = "\(baseKey).notifiedThresholds"

        let storedWindow = defaults.string(forKey: windowKey)
        let hasPreviousPercent = defaults.object(forKey: lastPercentKey) != nil
        guard let storedWindow, sameWindow(storedWindow, windowIdentifier), hasPreviousPercent else {
            defaults.set(windowIdentifier, forKey: windowKey)
            defaults.set(percent, forKey: lastPercentKey)
            defaults.removeObject(forKey: notifiedThresholdsKey)
            return
        }

        defaults.set(windowIdentifier, forKey: windowKey)   // follow small drifts in the reset time
        let previousPercent = defaults.integer(forKey: lastPercentKey)
        var notifiedThresholds = storedThresholds(forKey: notifiedThresholdsKey)
        let crossedThresholds = thresholds.filter { threshold in
            previousPercent < threshold && percent >= threshold && !notifiedThresholds.contains(threshold)
        }

        if !crossedThresholds.isEmpty {
            notifiedThresholds.formUnion(crossedThresholds)
            defaults.set(notifiedThresholds.sorted(), forKey: notifiedThresholdsKey)
            crossedThresholds.forEach { threshold in
                postNotification(provider: provider, metric: metric, threshold: threshold, percent: percent)
            }
        }

        defaults.set(percent, forKey: lastPercentKey)
    }

    private func postNotification(provider: Provider, metric: UsageMetric, threshold: Int, percent: Int) {
        let limit = limitName(for: metric)
        let reached = threshold >= 100
        let level = threshold >= 100 ? "\u{1F534}" : threshold >= 80 ? "\u{1F7E0}" : "\u{1F7E1}"

        let title = reached
            ? "\(level) \(provider.displayName) \(limit) limit reached"
            : "\(level) \(provider.displayName) \(limit) usage at \(threshold)%"
        let subtitle = metric.title

        // "▰▰▰▰▰▰▰▰▱▱ 80% used" plus when the window resets, if known.
        var lines = ["\(Self.progressBar(percent)) \(percent)% used"]
        if let detail = metric.detail { lines.append(detail) }
        let body = lines.joined(separator: "\n")

        let identifier = "usage-threshold-\(provider.id)-\(metric.id)-\(threshold)-\(UUID().uuidString)"
        let thread = provider.id
        let ring = Self.ringImageURL(percent: percent)
        let center = center

        center.getNotificationSettings { settings in
            func addNotification() {
                let content = UNMutableNotificationContent()
                content.title = title
                content.subtitle = subtitle
                content.body = body
                content.sound = .default
                content.threadIdentifier = thread     // group per provider in Notification Center
                if let ring, let attachment = try? UNNotificationAttachment(
                    identifier: "ring", url: ring, options: nil) {
                    content.attachments = [attachment]
                }

                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                center.add(request) { _ in }
            }

            switch settings.authorizationStatus {
            case .authorized, .provisional:
                addNotification()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    addNotification()
                }
            default:
                break
            }
        }
    }

    private static func progressBar(_ percent: Int, segments: Int = 10) -> String {
        let filled = min(max(Int((Double(percent) / 100 * Double(segments)).rounded()), 0), segments)
        return String(repeating: "\u{25B0}", count: filled) + String(repeating: "\u{25B1}", count: segments - filled)
    }

    /// Violet below 60%, amber below 80%, coral above — matches the popover bars.
    private static func accentColor(for percent: Int) -> NSColor {
        func rgb(_ hex: UInt) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        if percent >= 80 { return rgb(0xE8675C) }
        if percent >= 60 { return rgb(0xE3A24A) }
        return rgb(0x8B7FE8)
    }

    /// A circular progress ring with the percentage in the middle, used as the
    /// notification's thumbnail. Written to a temp file (the system copies it).
    static func ringImageURL(percent: Int) -> URL? {
        let size: CGFloat = 256, lineWidth: CGFloat = 26
        let accent = Self.accentColor(for: percent)
        let progress = min(max(CGFloat(percent) / 100, 0), 1)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let center = NSPoint(x: size / 2, y: size / 2)
        let radius = (size - lineWidth) / 2 - 8

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.gray.withAlphaComponent(0.28).setStroke()
        track.stroke()

        if progress > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * progress, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            accent.setStroke()
            arc.stroke()
        }

        let text = NSAttributedString(string: "\(Int((progress * 100).rounded()))%", attributes: [
            .font: NSFont.systemFont(ofSize: percent >= 100 ? 62 : 72, weight: .bold),
            .foregroundColor: accent,
        ])
        let textSize = text.size()
        text.draw(at: NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-ring-\(UUID().uuidString).png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    /// The CLIs' reset time wobbles by a minute between fetches ("4:59am" ↔ "5:00am").
    /// Treat two identifiers as the same window when only the clock time differs by
    /// up to two minutes — otherwise every wobble looks like a new window, resetting
    /// the baseline and swallowing the threshold crossing.
    private func sameWindow(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let pattern = #"(\d{1,2}):(\d{2})\s*([ap]m)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let ma = regex.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)),
              let mb = regex.firstMatch(in: b, range: NSRange(b.startIndex..., in: b)),
              let ra = Range(ma.range, in: a), let rb = Range(mb.range, in: b)
        else { return false }

        // Everything except the clock time (date, time zone) must match exactly.
        guard a.replacingCharacters(in: ra, with: "") == b.replacingCharacters(in: rb, with: "") else {
            return false
        }

        func minuteOfDay(_ match: NSTextCheckingResult, in text: String) -> Int? {
            guard let h = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
                  let m = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
                  let suffix = Range(match.range(at: 3), in: text).map({ text[$0].lowercased() })
            else { return nil }
            let hour24 = (h % 12) + (suffix == "pm" ? 12 : 0)
            return hour24 * 60 + m
        }
        guard let x = minuteOfDay(ma, in: a), let y = minuteOfDay(mb, in: b) else { return false }
        let diff = abs(x - y)
        return min(diff, 1440 - diff) <= 2
    }

    private func limitName(for metric: UsageMetric) -> String {
        let title = metric.title.lowercased()
        if title.contains("week") {
            return "weekly"
        }
        if title.contains("session") {
            return "session"
        }
        if title.contains("5h") {
            return "5h"
        }
        return metric.title
    }

    private func storedThresholds(forKey key: String) -> Set<Int> {
        Set((defaults.array(forKey: key) ?? []).compactMap { value in
            if let int = value as? Int {
                return int
            }
            if let number = value as? NSNumber {
                return number.intValue
            }
            return nil
        })
    }

    private func fallbackWindowIdentifier(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "captured-%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
