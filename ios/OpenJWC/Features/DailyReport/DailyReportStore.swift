import Foundation
import GRDB
import OpenJWCCore

/// 日报页状态机（对齐 Android DailyReportViewModel.UiState）：
/// 已完成日期列表观察 + 选中日内容懒加载 + 生成并发保护。
@MainActor
@Observable
final class DailyReportStore {
    /// 已完成日报（日期倒序，ValueObservation 驱动日期 chips）。
    private(set) var completedDays: [DailyReportRecord] = []
    /// 当前选中日；nil = 最新一份。
    var selectedDay: String?
    /// 选中日正文（懒加载）。
    private(set) var content: String?
    /// 正在生成中。
    private(set) var generating = false
    /// 生成失败（日 → 错误）。
    private(set) var failedDay: String?
    private(set) var failureMessage: String?
    private(set) var loading = false

    private let reportDao: DailyReportDao
    private let service: DailyReportService
    private let database: any DatabaseWriter
    private var observation: (any DatabaseCancellable)?

    init(db: any DatabaseWriter, service: DailyReportService) {
        self.reportDao = DailyReportDao(db: db)
        self.database = db
        self.service = service
        startObservation()
    }

    /// 目标日期：选中日 ?? 昨天（对齐 Android）。
    var targetDay: String {
        selectedDay ?? Self.dayString(Date().addingTimeInterval(-86_400))
    }

    func reload() async {
        loading = true
        defer { loading = false }
        let day = targetDay
        // 选中日优先取完成稿；未选中（默认态）取最近完成稿
        if selectedDay != nil {
            if let record = try? await reportDao.get(day: day),
               record.status == DailyReportStatus.completed.rawValue {
                content = record.content
                failedDay = nil
                failureMessage = nil
            } else if let record = try? await reportDao.get(day: day),
                      record.status == DailyReportStatus.failed.rawValue {
                content = nil
                failedDay = day
                failureMessage = record.error
            } else {
                content = nil
            }
        } else if let latest = try? await reportDao.latestCompleted(before: Self.dayString(Date().addingTimeInterval(86_400))) {
            content = latest.content
            failedDay = nil
            failureMessage = nil
        } else {
            content = nil
            failedDay = nil
            failureMessage = nil
        }
    }

    /// 手动生成（并发保护：生成中重复触发忽略；COMPLETED 不覆盖）。
    func generate() async {
        guard !generating else { return }
        generating = true
        failedDay = nil
        failureMessage = nil
        defer { generating = false }
        let day = targetDay
        do {
            _ = try await service.generate(day: day)
            selectedDay = day
            await reload()
        } catch DailyReportError.generationFailed(let message) {
            failedDay = day
            failureMessage = message
        } catch {
            failedDay = day
            failureMessage = error.localizedDescription
        }
    }

    func select(day: String) async {
        selectedDay = day
        await reload()
    }

    private func startObservation() {
        let observation = ValueObservation.tracking { db in
            try DailyReportDao.completedDaysSync(db)
        }
        .removeDuplicates()
        self.observation = observation.start(in: database, onError: { NSLog("DailyReportStore 观察错误: \($0)") }) { [weak self] value in
            Task { @MainActor in self?.completedDays = value }
        }
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
