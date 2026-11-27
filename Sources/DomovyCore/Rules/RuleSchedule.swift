import Foundation
import IOKit.ps

/// Once a day at a quiet hour. A Mac asleep at that hour runs at the next check after it.
public struct RuleSchedule: Hashable, Sendable {
    /// Local hour of the nightly run.
    public var hour: Int
    public var calendar: Calendar

    public init(hour: Int = 3, calendar: Calendar = .current) {
        self.hour = hour
        self.calendar = calendar
    }

    /// The latest run time at or before `now`.
    public func lastBoundary(atOrBefore now: Date) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    /// The first run time after `now`.
    public func nextBoundary(after now: Date) -> Date {
        let last = lastBoundary(atOrBefore: now)
        return calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86_400)
    }

    /// A run time passed since the last scheduled run (or since the scheduler first looked).
    public func isDue(now: Date, state: RuleScheduleState) -> Bool {
        guard let since = state.lastScheduledRun ?? state.anchor else { return false }
        return since < lastBoundary(atOrBefore: now)
    }

    /// When the next scheduled run happens: now if one is due.
    public func nextRun(now: Date, state: RuleScheduleState) -> Date {
        isDue(now: now, state: state) ? now : nextBoundary(after: now)
    }
}

/// Power at the moment a scheduled run would start.
public struct PowerState: Hashable, Sendable {
    public var isOnBattery: Bool
    /// 0–100, `nil` without a battery.
    public var batteryPercent: Int?
    public var isLowPowerMode: Bool

    public init(isOnBattery: Bool, batteryPercent: Int?, isLowPowerMode: Bool) {
        self.isOnBattery = isOnBattery
        self.batteryPercent = batteryPercent
        self.isLowPowerMode = isLowPowerMode
    }

    public static let pluggedIn = PowerState(isOnBattery: false, batteryPercent: nil, isLowPowerMode: false)

    /// Why a scheduled run waits, or `nil` when it may run.
    public var skipReason: String? {
        if isLowPowerMode { return "Skipped: Low Power Mode is on. The rules run at the next check." }
        if isOnBattery, let percent = batteryPercent, percent < 20 {
            return "Skipped: on battery at \(percent)%. The rules run at the next check."
        }
        return nil
    }

    /// Read from IOKit; plugged in when there is no battery or it cannot be read.
    public static func current() -> PowerState {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerState(isOnBattery: false, batteryPercent: nil, isLowPowerMode: lowPower)
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            var percent: Int?
            if let current = description[kIOPSCurrentCapacityKey] as? Int, let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = current * 100 / max
            }
            return PowerState(isOnBattery: onBattery, batteryPercent: percent, isLowPowerMode: lowPower)
        }
        return PowerState(isOnBattery: false, batteryPercent: nil, isLowPowerMode: lowPower)
    }
}
