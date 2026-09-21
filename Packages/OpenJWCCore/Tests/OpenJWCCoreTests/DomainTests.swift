import Foundation
import Testing
@testable import OpenJWCCore

/// Requirement: 会话/消息/工具卡持久化 + 课表持久化 + 数据源注册表 + 日报
@Suite("Chat / Timetable / Source / Report")
struct ChatAndMoreTests {
    let provider: DatabaseProvider
    let chat: ChatDao
    let timetable: TimetableDao
    let source: SourceDao
    let report: DailyReportDao

    init() throws {
        provider = try TestDB.makeInMemory()
        chat = ChatDao(db: provider.dbWriter)
        timetable = TimetableDao(db: provider.dbWriter)
        source = SourceDao(db: provider.dbWriter)
        report = DailyReportDao(db: provider.dbWriter)
    }

    @Test("工具轨迹随消息落库，重启后按 position 还原")
    func toolTrailRestored() async throws {
        let sessionId = try await chat.insertMetadata(ChatSessionRecord(title: "s", lastUpdated: 1))
        let messageId = try await chat.insertMessage(ChatMessageRecord(
                messageId: nil, ownerSessionId: sessionId, text: "查询", role: .assistant,
                attachmentTitles: JSONStringList([]), attachmentIds: JSONStringList(["n1"]),
                status: .running, runId: "r1", delivery: nil, errorCode: nil, timestamp: 1
            ))
        let call0 = try await chat.insertToolCall(ChatToolCallRecord(
                id: nil, messageId: messageId, position: 1, name: "read_notice",
                summary: "读资讯", status: "RUNNING", code: nil, durationMs: nil, targetId: "n1"
            ))
        _ = try await chat.insertToolCall(ChatToolCallRecord(
                id: nil, messageId: messageId, position: 0, name: "search_notices",
                summary: "搜资讯", status: "COMPLETED", code: nil, durationMs: 12, targetId: nil
            ))
        try await chat.completeToolCall(id: call0, status: "COMPLETED", code: nil, durationMs: 30)
        try await chat.finishMessage(messageId: messageId, text: "答案", status: .completed, delivery: "streaming-final", errorCode: nil)

        let turns = try await chat.turns(sessionId: sessionId)
        #expect(turns.count == 1)
        #expect(turns[0].toolCalls.map(\.name) == ["search_notices", "read_notice"]) // position 有序
        #expect(turns[0].toolCalls[1].durationMs == 30)
        #expect(turns[0].message.status == .completed)
        #expect(turns[0].message.delivery == "streaming-final")
        #expect(turns[0].message.attachmentIds.value == ["n1"])
    }

    @Test("runId 回写与消息删除")
    func runIdAndDelete() async throws {
        let sessionId = try await chat.insertMetadata(ChatSessionRecord(title: "s", lastUpdated: 1))
        let messageId = try await chat.insertMessage(ChatMessageRecord(
                messageId: nil, ownerSessionId: sessionId, text: "t", role: .assistant,
                attachmentTitles: JSONStringList([]), attachmentIds: JSONStringList([]),
                status: .running, runId: nil, delivery: nil, errorCode: nil, timestamp: 1
            ))
        try await chat.updateMessageRunId(messageId: messageId, runId: "run-9")
        var msg = try await chat.messages(sessionId: sessionId)[0]
        #expect(msg.runId == "run-9")
        try await chat.deleteMessageById(messageId: messageId)
        msg = try await chat.messages(sessionId: sessionId).first ?? msg
        #expect((try await chat.messages(sessionId: sessionId)).isEmpty)
    }

    @Test("更新课表元数据不清空其课程（REPLACE 级联陷阱锁定）")
    func tableUpdateKeepsCourses() async throws {
        let tableId = try await timetable.insertTable(TableMetadataRecord(
                id: nil, tableName: "主表", semesterConfig: SemesterConfig(startDate: "2026-09-07", weeks: 16, visibleDays: [1, 2], periods: []), isCurrent: true
            ))
        try await timetable.upsertCourse(CourseRecord(
            id: nil, tableId: tableId, name: "数学", teacher: "", location: "",
            dayOfWeek: 1, startPeriod: 1, duration: 2, color: 0xFF3366CC, weekRule: JSONIntSet([1, 3]), note: ""
        ))
        // 用相同 id 更新（Android @Insert(REPLACE) 在此会级联清空课程）
        try await timetable.insertTable(TableMetadataRecord(
            id: tableId, tableName: "主表改名", semesterConfig: SemesterConfig(startDate: "2026-09-07", weeks: 16, visibleDays: [1, 2], periods: []), isCurrent: true
        ))
        let courses = try await timetable.courses(tableId: tableId)
        #expect(courses.count == 1)
        #expect(courses[0].name == "数学")
    }

    @Test("切换当前课表原子性 + deleteEmptyTables")
    func currentTableSwitch() async throws {
        let t1 = try await timetable.insertTable(TableMetadataRecord(id: nil, tableName: "A", semesterConfig: SemesterConfig(startDate: "", weeks: 1, visibleDays: [], periods: []), isCurrent: true))
        let t2 = try await timetable.insertTable(TableMetadataRecord(id: nil, tableName: "B", semesterConfig: SemesterConfig(startDate: "", weeks: 1, visibleDays: [], periods: []), isCurrent: false))
        try await timetable.setCurrentTable(tableId: t2)
        let current = try await timetable.currentTable()
        #expect(current?.id == t2)
        try await timetable.deleteTableById(tableId: t2)
        // A 无课程也会被 deleteEmptyTables 清理：先给 A 挂一门课
        try await timetable.upsertCourse(CourseRecord(
            id: nil, tableId: t1, name: "数学", teacher: "", location: "",
            dayOfWeek: 1, startPeriod: 1, duration: 2, color: 0, weekRule: JSONIntSet([1]), note: ""
        ))
        try await timetable.deleteEmptyTables()
        let tables = try await timetable.allTables()
        #expect(tables.map(\.tableName) == ["A"])
    }

    @Test("数据源置顶排序：subscribed DESC → seu-jwc 置顶 → origin DESC → name ASC")
    func sourceOrdering() async throws {
        try await source.upsertAll([
            mkSource("seu-cs", name: "计算机", subscribed: false, origin: "builtin"),
            mkSource("custom-x", name: "自定义", subscribed: false, origin: "sideload"),
            mkSource("seu-jwc", name: "教务处", subscribed: false, origin: "builtin"),
            mkSource("seu-law", name: "法学院", subscribed: true, origin: "builtin"),
        ])
        let rows = try await source.getAll()
        #expect(rows.map(\.id) == ["seu-law", "seu-jwc", "custom-x", "seu-cs"]) // origin DESC: sideload > builtin
        try await source.setSubscribed(id: "seu-cs", subscribed: true)
        let subscribed = try await source.getSubscribed()
        #expect(Set(subscribed.map(\.id)) == ["seu-law", "seu-cs"])
    }

    @Test("日报防降级守卫：completed 不被覆盖")
    func dailyReportGuard() async throws {
        try await report.save(day: "2026-09-19", status: "completed", content: "成品", sourceCount: 3, error: nil, updatedAt: 1)
        try await report.save(day: "2026-09-19", status: "running", content: "重跑", sourceCount: 0, error: nil, updatedAt: 2)
        let row = try await report.get(day: "2026-09-19")
        #expect(row?.status == "completed")
        #expect(row?.content == "成品")
        let latest = try await report.latestCompleted(before: "2026-09-20")
        #expect(latest?.day == "2026-09-19")
    }

    private func mkSource(_ id: String, name: String, subscribed: Bool, origin: String) -> NoticeSourceRecord {
        NoticeSourceRecord(
            id: id, name: name, version: "1.0", origin: origin, scriptFile: nil,
            domains: JSONStringList(["x.edu.cn"]), labels: JSONStringList(["L"]),
            scheduleMinutes: 360, subscribed: subscribed, lastRunAt: nil, lastCount: 0, lastError: nil
        )
    }
}
