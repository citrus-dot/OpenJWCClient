import Foundation
import Testing
@testable import OpenJWCCore

/// TimetableLayout 测试（tasks 1.6）：泳道族 / 落点族 / 冲突族 / 周次文案族。
@Suite("TimetableLayout 布局算法")
struct TimetableLayoutTests {

    // MARK: - 夹具

    private func course(
        id: Int64? = 1, tableId: Int64 = 1, name: String = "课",
        day: Int = 1, start: Int = 1, duration: Int = 2,
        weeks: Set<Int> = Set(1...16)
    ) -> CourseRecord {
        CourseRecord(
            id: id, tableId: tableId, name: name, teacher: "", location: "",
            dayOfWeek: day, startPeriod: start, duration: duration,
            color: 0xFF000000, weekRule: JSONIntSet(weeks), note: ""
        )
    }

    private func period(_ index: Int, start: String, end: String) -> SemesterConfig.Period {
        SemesterConfig.Period(index: index, start: start, end: end)
    }

    private let periods8 = (1...8).map { i in
        SemesterConfig.Period(
            index: i,
            start: String(format: "%02d:00", 7 + i * 2),
            end: String(format: "%02d:45", 7 + i * 2)
        )
    }

    // MARK: - findContinuousBlocks

    @Test("连续节次拆段：1,2,4,5 → [1,2],[4,5]；空/单元素")
    func continuousBlocks() {
        #expect(TimetableLayout.findContinuousBlocks([]) == [])
        #expect(TimetableLayout.findContinuousBlocks([3]) == [[3]])
        #expect(TimetableLayout.findContinuousBlocks([1, 2, 4, 5]) == [[1, 2], [4, 5]])
        #expect(TimetableLayout.findContinuousBlocks([1, 2, 3]) == [[1, 2, 3]])
        #expect(TimetableLayout.findContinuousBlocks([1, 3, 5, 7]) == [[1], [3], [5], [7]])
    }

    // MARK: - columnLayout / 泳道

    @Test("本周课程全列宽 + 非本周裁剪后消失")
    func thisWeekOnly() {
        let thisWeek = course(id: 1, start: 1, duration: 2, weeks: Set([3]))
        let other = course(id: 2, start: 1, duration: 2, weeks: Set([5]))
        let layout = TimetableLayout.columnLayout(
            dayCourses: [thisWeek, other], currentWeek: 3, showNonCurrentWeek: true, draggingId: nil
        )
        #expect(layout.thisWeek.map(\.id) == [1])
        #expect(layout.otherSegments.isEmpty) // 1-2 节被本周课程完全占用
    }

    @Test("非本周两门不重叠 → 同组两条泳道；相邻节段重叠 → 传递分组")
    func laneAssignments() {
        // A: 1-2 节、B: 2-3 节（2 节重叠 → 传递性同组）→ 2 泳道
        let a = course(id: 1, start: 1, duration: 2, weeks: Set([5]))
        let b = course(id: 2, start: 2, duration: 2, weeks: Set([6]))
        let layout = TimetableLayout.columnLayout(
            dayCourses: [a, b], currentWeek: 1, showNonCurrentWeek: true, draggingId: nil
        )
        #expect(layout.thisWeek.isEmpty)
        #expect(layout.otherSegments.count == 2)
        #expect(layout.otherSegments.allSatisfy { $0.laneCount == 2 })
        let lanes = Set(layout.otherSegments.map(\.lane))
        #expect(lanes == [0, 1])

        // C: 5-6 节与上面不重叠 → 独立组 1 泳道
        let c = course(id: 3, start: 5, duration: 2, weeks: Set([5]))
        let layout2 = TimetableLayout.columnLayout(
            dayCourses: [a, b, c], currentWeek: 1, showNonCurrentWeek: true, draggingId: nil
        )
        let cSegments = layout2.otherSegments.filter { $0.course.id == 3 }
        #expect(cSegments.count == 1)
        #expect(cSegments[0].lane == 0)
        #expect(cSegments[0].laneCount == 1)
    }

    @Test("拖动中课程不占位：露层 + 原课仍在本周列表（UI 隐藏）")
    func draggingExposesLayer() {
        let thisWeek = course(id: 1, start: 1, duration: 2, weeks: Set([3]))
        let other = course(id: 2, start: 1, duration: 2, weeks: Set([5]))
        let layout = TimetableLayout.columnLayout(
            dayCourses: [thisWeek, other], currentWeek: 3, showNonCurrentWeek: true, draggingId: 1
        )
        // 拖动中：本周课不占 1-2 节 → 非本周课完整显形（1-2 节一条分段）
        #expect(layout.thisWeek.count == 1)
        #expect(layout.otherSegments.count == 1)
        #expect(layout.otherSegments[0].periods == [1, 2])
    }

    @Test("非本周部分重叠裁剪：跨周分段拆连续块")
    func partialClipSplitsBlocks() {
        // 本周占 2 节；非本周 1-3 节 → 可见 [1, 3] → 拆两段
        let thisWeek = course(id: 1, start: 2, duration: 1, weeks: Set([3]))
        let other = course(id: 2, start: 1, duration: 3, weeks: Set([5]))
        let layout = TimetableLayout.columnLayout(
            dayCourses: [thisWeek, other], currentWeek: 3, showNonCurrentWeek: true, draggingId: nil
        )
        let segments = layout.otherSegments.filter { $0.course.id == 2 }
        #expect(segments.count == 2)
        #expect(segments.map(\.periods) == [[1], [3]])
    }

    @Test("showNonCurrentWeek=false 时非本周全部隐藏")
    func hideNonCurrentWeek() {
        let other = course(id: 2, start: 1, duration: 2, weeks: Set([5]))
        let layout = TimetableLayout.columnLayout(
            dayCourses: [other], currentWeek: 1, showNonCurrentWeek: false, draggingId: nil
        )
        #expect(layout.otherSegments.isEmpty)
        #expect(layout.thisWeek.isEmpty)
    }

    // MARK: - resolveDropTarget

    private let days = [1, 2, 3, 4, 5, 6, 7]

    @Test("落点：中心定列 + 上缘定节（四舍五入）")
    func dropTargetBasic() {
        let moving = course(id: 9, day: 1, start: 1, duration: 2)
        // colWidth=100, label=50, periodHeight=60
        // 中心 = x+50；x=180 → 中心 230 → (230-50)/100=1.8 → 列 1（周二）
        // y=90 → 90/60=1.5 → round=2 → 第 3 节
        let target = TimetableLayout.resolveDropTarget(
            course: moving, dragPositionX: 180, dragPositionY: 90,
            colWidth: 100, timeLabelWidth: 50, periodHeight: 60,
            sortedVisibleDays: days, periods: periods8, courses: [moving]
        )
        #expect(target?.dayOfWeek == 2)
        #expect(target?.startPeriod == 3)
    }

    @Test("落点：clamp 列与节；整块越界 nil")
    func dropTargetClampAndReject() {
        let moving = course(id: 9, day: 1, start: 1, duration: 2)
        // 负坐标 → 列 0 / 节 0
        let clamped = TimetableLayout.resolveDropTarget(
            course: moving, dragPositionX: -500, dragPositionY: -50,
            colWidth: 100, timeLabelWidth: 50, periodHeight: 60,
            sortedVisibleDays: days, periods: periods8, courses: [moving]
        )
        #expect(clamped?.dayOfWeek == 1)
        #expect(clamped?.startPeriod == 1)

        // duration=2、第 8 节起 → end=9 > 8 → nil（round 后 clamp 至 maxStartIndex=6 → 不越界）
        // 用 duration=1 且 y 极大：round(600/60)=10 clamp 到 7（第 8 节），end=8 不越界 → 有效
        let single = TimetableLayout.resolveDropTarget(
            course: course(id: 9, day: 1, start: 1, duration: 1),
            dragPositionX: 100, dragPositionY: 600,
            colWidth: 100, timeLabelWidth: 50, periodHeight: 60,
            sortedVisibleDays: days, periods: periods8, courses: []
        )
        #expect(single?.startPeriod == 8)
    }

    @Test("落点：与其它课程冲突 nil；自身位置不冲突")
    func dropTargetConflict() {
        let moving = course(id: 9, day: 1, start: 1, duration: 2, weeks: Set(1...16))
        let resident = course(id: 2, day: 2, start: 3, duration: 2, weeks: Set(1...16))
        // 拖到周二第 2 节（2-3 节与 3-4 重叠且周次交集）→ nil
        // 中心 = x+50 落周二 → x ∈ (100, 200)；取 x=120；y=120 → round(2)=2 → 第 3 节起（2-3 与 3-4 重叠）
        let conflict = TimetableLayout.resolveDropTarget(
            course: moving, dragPositionX: 120, dragPositionY: 120,
            colWidth: 100, timeLabelWidth: 50, periodHeight: 60,
            sortedVisibleDays: days, periods: periods8, courses: [moving, resident]
        )
        #expect(conflict == nil)

        // 同参但 courses 不含 resident → 有效
        let free = TimetableLayout.resolveDropTarget(
            course: moving, dragPositionX: 120, dragPositionY: 120,
            colWidth: 100, timeLabelWidth: 50, periodHeight: 60,
            sortedVisibleDays: days, periods: periods8, courses: [moving]
        )
        #expect(free?.dayOfWeek == 2)
        #expect(free?.startPeriod == 3)
    }

    @Test("落点：零尺寸/空配置 nil")
    func dropTargetDegenerate() {
        let moving = course(id: 9)
        #expect(TimetableLayout.resolveDropTarget(
            course: moving, dragPositionX: 0, dragPositionY: 0,
            colWidth: 0, timeLabelWidth: 50, periodHeight: 60,
            sortedVisibleDays: days, periods: periods8, courses: []
        ) == nil)
        #expect(TimetableLayout.resolveDropTarget(
            course: moving, dragPositionX: 0, dragPositionY: 0,
            colWidth: 100, timeLabelWidth: 50, periodHeight: 60,
            sortedVisibleDays: [], periods: periods8, courses: []
        ) == nil)
    }

    // MARK: - isConflicting

    @Test("冲突五条件边界")
    func conflictRules() {
        let base = course(id: 1, tableId: 1, day: 2, start: 3, duration: 2, weeks: Set([1, 2, 3]))

        // 完全同参但同 id → 不冲突（自身）
        #expect(!TimetableLayout.isConflicting(base, base))

        // 同参数异 id → 冲突
        #expect(TimetableLayout.isConflicting(base, course(id: 2, tableId: 1, day: 2, start: 3, duration: 2, weeks: Set([1, 2, 3]))))

        // 异表 → 不冲突
        #expect(!TimetableLayout.isConflicting(base, course(id: 2, tableId: 2, day: 2, start: 3, duration: 2, weeks: Set([1, 2, 3]))))

        // 新课 id=0 与任何已存课 → 参与冲突判定
        #expect(TimetableLayout.isConflicting(course(id: 0, tableId: 1, day: 2, start: 3, duration: 2, weeks: Set([2])), base))

        // 异天 → 不冲突
        #expect(!TimetableLayout.isConflicting(base, course(id: 2, tableId: 1, day: 3, start: 3, duration: 2, weeks: Set([1, 2, 3]))))

        // 相邻不重叠（3-4 与 5-6）→ 不冲突
        #expect(!TimetableLayout.isConflicting(base, course(id: 2, tableId: 1, day: 2, start: 5, duration: 2, weeks: Set([1, 2, 3]))))

        // 重叠但周次无交集 → 不冲突
        #expect(!TimetableLayout.isConflicting(base, course(id: 2, tableId: 1, day: 2, start: 4, duration: 2, weeks: Set([4, 5]))))

        // 重叠且周次交集（仅第 2 周）→ 冲突
        #expect(TimetableLayout.isConflicting(base, course(id: 2, tableId: 1, day: 2, start: 4, duration: 2, weeks: Set([2, 9]))))
    }

    // MARK: - formatWeekRule

    @Test("周次文案：每周/单/双/区间压缩/空")
    func weekRuleText() {
        #expect(TimetableLayout.formatWeekRule([], totalWeeks: 16) == "")
        #expect(TimetableLayout.formatWeekRule(Set(1...16), totalWeeks: 16) == "每周")
        #expect(TimetableLayout.formatWeekRule(Set(1...16).union([20]), totalWeeks: 16) == "每周") // containsAll 语义
        #expect(TimetableLayout.formatWeekRule(Set((1...16).filter { $0 % 2 != 0 }), totalWeeks: 16) == "单周")
        #expect(TimetableLayout.formatWeekRule(Set((1...16).filter { $0 % 2 == 0 }), totalWeeks: 16) == "双周")
        #expect(TimetableLayout.formatWeekRule([1, 2, 3, 4, 6], totalWeeks: 16) == "1-4, 6 周")
        #expect(TimetableLayout.formatWeekRule([7], totalWeeks: 16) == "7 周")
        #expect(TimetableLayout.formatWeekRule([5, 6], totalWeeks: 16) == "5-6 周")
    }
}
