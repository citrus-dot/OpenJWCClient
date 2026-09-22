import Foundation
import CoreGraphics

// MARK: - 周视图布局纯函数（直译 Android CourseLayer.kt / TimetableGridUtils.kt / TimetableGrid.kt 落点 / Course.isConflictingWith）

/// 非本周课程的一个可见分段及其并排泳道信息（对齐 Android LaneBlock）。
public struct TimetableLaneSegment: Equatable, Sendable {
    public var course: CourseRecord
    /// 该分段占用的节次号（1-based，连续）。
    public var periods: [Int]
    /// 组内泳道序号（0-based）。
    public var lane: Int
    /// 组内泳道总数（宽度 = 列宽 ÷ laneCount）。
    public var laneCount: Int

    public init(course: CourseRecord, periods: [Int], lane: Int, laneCount: Int) {
        self.course = course
        self.periods = periods
        self.lane = lane
        self.laneCount = laneCount
    }
}

public enum TimetableLayout {

    // MARK: - 泳道布局（对齐 CourseColumnScope 预计算 + assignLanes）

    /// 单列布局结果：本周课程（全列宽顶层）+ 非本周泳道分段（底层淡显）。
    public struct ColumnLayout: Equatable, Sendable {
        public var thisWeek: [CourseRecord]
        public var otherSegments: [TimetableLaneSegment]
    }

    /// 计算一天的课程布局。`draggingId` 的课程不占本周节次（露出下层），
    /// 且对应原位块由 UI 层隐藏（alpha 0）。
    public static func columnLayout(
        dayCourses: [CourseRecord],
        currentWeek: Int,
        showNonCurrentWeek: Bool,
        draggingId: Int64?
    ) -> ColumnLayout {
        let (thisWeek, otherWeeks) = dayCourses.partitioned { $0.weekRule.value.contains(currentWeek) }

        // 本周课程占用的节次；拖动中的课程不再占位，露出其下方的非本周课程
        var occupiedByThisWeek = Set<Int>()
        for course in thisWeek where course.id != draggingId {
            for period in course.startPeriod..<(course.startPeriod + course.duration) {
                occupiedByThisWeek.insert(period)
            }
        }

        // 非本周课程只按【本周课程】裁剪，彼此之间改用并排泳道而非互相遮盖
        var otherSegments: [(CourseRecord, [Int])] = []
        if showNonCurrentWeek {
            for course in otherWeeks {
                let courseRange = course.startPeriod..<(course.startPeriod + course.duration)
                let visiblePeriods = courseRange.filter { !occupiedByThisWeek.contains($0) }
                if !visiblePeriods.isEmpty {
                    for block in findContinuousBlocks(visiblePeriods) {
                        otherSegments.append((course, block))
                    }
                }
            }
        }

        return ColumnLayout(thisWeek: thisWeek, otherSegments: assignLanes(otherSegments))
    }

    /// 将不连续的节次索引（如 1, 2, 4, 5）拆分为块（如 [1,2], [4,5]）。
    public static func findContinuousBlocks(_ periods: [Int]) -> [[Int]] {
        guard !periods.isEmpty else { return [] }
        var blocks: [[Int]] = []
        var currentBlock: [Int] = [periods[0]]
        for i in 1..<periods.count {
            if periods[i] == periods[i - 1] + 1 {
                currentBlock.append(periods[i])
            } else {
                blocks.append(currentBlock)
                currentBlock = [periods[i]]
            }
        }
        blocks.append(currentBlock)
        return blocks
    }

    /// 为互相重叠的非本周课程分段分配并排泳道：
    /// 先把传递性重叠的分段归为一组，组内贪心选择第一条空闲泳道。
    static func assignLanes(_ segments: [(CourseRecord, [Int])]) -> [TimetableLaneSegment] {
        guard !segments.isEmpty else { return [] }
        let sorted = segments.sorted { ($0.1.first ?? 0) < ($1.1.first ?? 0) }
        var result: [TimetableLaneSegment] = []
        var group: [(CourseRecord, [Int])] = []
        var groupEnd = -1

        func flushGroup() {
            guard !group.isEmpty else { return }
            var laneEnds: [Int] = []
            var laneOf: [Int] = []
            for (_, periods) in group {
                let start = periods.first ?? 0
                let end = periods.last ?? 0
                if let freeLane = laneEnds.firstIndex(where: { $0 < start }) {
                    laneEnds[freeLane] = end
                    laneOf.append(freeLane)
                } else {
                    laneEnds.append(end)
                    laneOf.append(laneEnds.count - 1)
                }
            }
            let laneCount = laneEnds.count
            for (index, (course, periods)) in group.enumerated() {
                result.append(TimetableLaneSegment(
                    course: course, periods: periods, lane: laneOf[index], laneCount: laneCount
                ))
            }
            group.removeAll()
            groupEnd = -1
        }

        for segment in sorted {
            guard let start = segment.1.first, let end = segment.1.last else { continue }
            if !group.isEmpty && start > groupEnd {
                flushGroup()
            }
            group.append(segment)
            groupEnd = max(groupEnd, end)
        }
        flushGroup()
        return result
    }

    // MARK: - 落点解算（对齐 TimetableGrid.resolveDropTarget）

    /// 落点解算结果：目标星期（ISO 1–7）与起始节次号。
    public struct DropTarget: Equatable, Sendable {
        public var dayOfWeek: Int
        public var startPeriod: Int
    }

    /// 根据被拖动块左上角的位置计算落点（星期 + 起始节次）。
    /// 若越界或与其它课程冲突则返回 nil（调用方据此回弹）。
    /// - Parameters:
    ///   - dragPosition: 浮层左上角在网格坐标系内的位置（pt）。
    ///   - periods: 节次配置（须按 index 升序）。
    ///   - courses: 当前表全部课程（冲突判定域）。
    public static func resolveDropTarget(
        course: CourseRecord,
        dragPositionX: CGFloat,
        dragPositionY: CGFloat,
        colWidth: CGFloat,
        timeLabelWidth: CGFloat,
        periodHeight: CGFloat,
        sortedVisibleDays: [Int],
        periods: [SemesterConfig.Period],
        courses: [CourseRecord]
    ) -> DropTarget? {
        guard colWidth > 0, periodHeight > 0,
              !periods.isEmpty, !sortedVisibleDays.isEmpty else { return nil }

        // 以块的水平中心决定目标列
        let centerX = dragPositionX + colWidth / 2
        let dayIndex = Int((centerX - timeLabelWidth) / colWidth)
            .clamped(to: 0...(sortedVisibleDays.count - 1))

        // 以块的上边缘决定起始节次，并保证整块落在网格内
        let maxStartIndex = max(periods.count - course.duration, 0)
        let periodIndex = Int((dragPositionY / periodHeight).rounded())
            .clamped(to: 0...maxStartIndex)

        let day = sortedVisibleDays[dayIndex]
        let startPeriod = periods[periodIndex].index
        let endPeriod = startPeriod + course.duration - 1
        if endPeriod > (periods.last?.index ?? 0) { return nil }

        var candidate = course
        candidate.dayOfWeek = day
        candidate.startPeriod = startPeriod
        let hasConflict = courses.contains { other in
            other.id != course.id && isConflicting(candidate, other)
        }
        if hasConflict { return nil }

        return DropTarget(dayOfWeek: day, startPeriod: startPeriod)
    }

    // MARK: - 冲突判定（直译 Course.isConflictingWith）

    /// 同表 + 异 id（id==0 视为新课不参与同 id 排除）+ 同天 + 节次区间重叠 + 周次交集。
    public static func isConflicting(_ lhs: CourseRecord, _ rhs: CourseRecord) -> Bool {
        if lhs.tableId != rhs.tableId { return false }
        if let lhsId = lhs.id, lhsId != 0, lhsId == rhs.id { return false }
        if lhs.dayOfWeek != rhs.dayOfWeek { return false }
        let thisEnd = lhs.startPeriod + lhs.duration - 1
        let otherEnd = rhs.startPeriod + rhs.duration - 1
        let overlaps = max(lhs.startPeriod, rhs.startPeriod) <= min(thisEnd, otherEnd)
        let sharesWeek = !lhs.weekRule.value.isDisjoint(with: rhs.weekRule.value)
        return overlaps && sharesWeek
    }

    // MARK: - 周次文案（直译 TimetableGridUtils.formatWeekRule）

    /// 每周/单周/双周/自定义区间压缩（如「1-4, 6 周」）。
    public static func formatWeekRule(
        _ weekRule: Set<Int>,
        totalWeeks: Int,
        everyWeekStr: String = "每周",
        oddWeeksStr: String = "单周",
        evenWeeksStr: String = "双周",
        customWeeksStr: String = "周"
    ) -> String {
        if weekRule.isEmpty { return "" }
        let sorted = weekRule.sorted()

        // 直译：sorted.size >= totalWeeks && sorted.containsAll((1..totalWeeks))
        if totalWeeks > 0, sorted.count >= totalWeeks,
           Set(sorted).isSuperset(of: Set(1...totalWeeks)) {
            return everyWeekStr
        }

        let oddWeeks = (1...totalWeeks).filter { $0 % 2 != 0 }
        let evenWeeks = (1...totalWeeks).filter { $0 % 2 == 0 }
        if sorted == oddWeeks { return oddWeeksStr }
        if sorted == evenWeeks { return evenWeeksStr }

        var ranges: [String] = []
        if !sorted.isEmpty {
            var start = sorted[0]
            var end = sorted[0]
            for i in 1..<sorted.count {
                if sorted[i] == end + 1 {
                    end = sorted[i]
                } else {
                    ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
                    start = sorted[i]
                    end = sorted[i]
                }
            }
            ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
        }
        return ranges.joined(separator: ", ") + " " + customWeeksStr
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Array {
    /// 等价 Kotlin `partition`（顺序保持）。
    func partitioned(by predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self where predicate(element) {
            matching.append(element)
        }
        for element in self where !predicate(element) {
            rest.append(element)
        }
        return (matching, rest)
    }
}
