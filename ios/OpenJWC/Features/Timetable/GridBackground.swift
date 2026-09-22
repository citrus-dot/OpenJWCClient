import SwiftUI
import OpenJWCCore

// MARK: - 背景层（直译 GridBackgroundLayer：网格线 + 活跃行高亮 + 节次标签；空槽 tap 在 GridView 统一层）

struct GridBackgroundLayer: View {
    let config: SemesterConfig
    let sortedVisibleDays: [Int]
    let periodHeight: CGFloat
    let timeLabelWidth: CGFloat
    let activePeriodIndex: Int
    let showPeriodTime: Bool
    let totalWidth: CGFloat

    var body: some View {
        let totalHeight = periodHeight * CGFloat(config.periods.count)

        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let gridColor = Color.secondary.opacity(0.25)
                let rows = config.periods.count

                // 活跃节行高亮
                if activePeriodIndex >= 0 && activePeriodIndex < rows {
                    let rect = CGRect(
                        x: timeLabelWidth,
                        y: periodHeight * CGFloat(activePeriodIndex),
                        width: size.width - timeLabelWidth,
                        height: periodHeight
                    )
                    context.fill(Path(rect), with: .color(.accentColor.opacity(0.08)))
                }

                // 水平线
                for i in 0...rows {
                    let y = periodHeight * CGFloat(i)
                    context.stroke(
                        Path { p in
                            p.move(to: CGPoint(x: timeLabelWidth, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                        },
                        with: .color(gridColor), lineWidth: 0.5
                    )
                }
                // 垂直线（含节次栏右缘）
                for i in 0...sortedVisibleDays.count {
                    let x = timeLabelWidth + CGFloat(i) * ((size.width - timeLabelWidth) / CGFloat(max(sortedVisibleDays.count, 1)))
                    context.stroke(
                        Path { p in
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: totalHeight))
                        },
                        with: .color(gridColor), lineWidth: 0.5
                    )
                }
            }

            // 节次标签列（节号 + HH:mm）
            VStack(spacing: 0) {
                ForEach(config.periods, id: \.index) { period in
                    VStack(spacing: 2) {
                        Text("\(period.index)")
                            .font(.caption2.weight(.medium))
                        if showPeriodTime {
                            Text(period.start)
                                .font(.system(size: 8))
                            Text(period.end)
                                .font(.system(size: 8))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: timeLabelWidth, height: periodHeight)
                }
            }
        }
        .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
    }
}

// MARK: - 时间指示线（直译 TimeIndicatorLine：节内分钟插值 / 节间贴下节上缘 / 界外隐藏）

struct TimeIndicatorLine: View {
    let periods: [SemesterConfig.Period]
    let periodHeight: CGFloat
    let timeLabelWidth: CGFloat
    let totalWidth: CGFloat
    let nowMinuteOfDay: Int

    var body: some View {
        if let offsetPeriods = TimetableStore.timeLineOffsetPeriods(
            minuteOfDay: nowMinuteOfDay, periods: periods
        ) {
            let y = CGFloat(offsetPeriods) * periodHeight
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .offset(x: -4)
            }
            .frame(width: totalWidth - timeLabelWidth, height: 2)
            .offset(x: timeLabelWidth, y: y - 1)
        }
    }
}

// MARK: - 周日期表头（今天高亮 + 跨午夜刷新）

struct TimetableHeaderRow: View {
    let currentWeek: Int
    let startDate: String
    let sortedVisibleDays: [Int]
    let timeLabelWidth: CGFloat
    let titleHeight: CGFloat
    let showDate: Bool

    @State private var today = Calendar.current.startOfDay(for: Date())
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            Text("第 \(currentWeek) 周")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: timeLabelWidth, height: titleHeight)
            ForEach(sortedVisibleDays, id: \.self) { day in
                let date = weekDate(for: day)
                let isToday = date == today
                VStack(spacing: 2) {
                    Text(Self.dayNames[day - 1])
                        .font(.caption.weight(isToday ? .bold : .regular))
                    if showDate {
                        Text(Self.dayFormatter.string(from: date))
                            .font(.system(size: 9))
                    }
                }
                .foregroundStyle(isToday ? Color.white : Color.secondary)
                .background(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: Capsule())
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: titleHeight)
        .onReceive(timer) { _ in
            today = Calendar.current.startOfDay(for: Date())
        }
    }

    /// 开学周一 + (N−1) 周 + (day−1) 天（startDate 归一周一）。
    private func weekDate(for day: Int) -> Date {
        let calendar = Calendar.current
        let base = Self.parseMonday(startDate) ?? calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: (currentWeek - 1) * 7 + day - 1, to: base) ?? base
    }

    static func parseMonday(_ s: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: s) else { return nil }
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let weekday = calendar.component(.weekday, from: date)
        let offset = (weekday + 5) % 7 // 周一 → 0；周日 → 6
        return calendar.date(byAdding: .day, value: -offset, to: date)
    }

    static let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()
}
