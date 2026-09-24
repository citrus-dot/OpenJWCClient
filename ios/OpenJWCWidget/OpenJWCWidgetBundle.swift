import WidgetKit
import SwiftUI
import OpenJWCCore

@main
struct OpenJWCWidgetBundle: WidgetBundle {
    var body: some Widget {
        CourseWidget()
    }
}

/// 课程小组件（systemSmall/Medium/Large；Medium 为对齐 Android 4×2 的基准尺寸）。
struct CourseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "org.openjwc.course", provider: CourseTimelineProvider()) { entry in
            CourseWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("课程表")
        .description(Text("一眼看今天剩什么课。数据来自 OpenJWC 主应用。"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled() // 自管内边距（对齐 Android 紧凑课程卡布局）
    }
}

// MARK: - TimelineProvider

struct CourseEntry: TimelineEntry {
    let date: Date
    let state: WidgetDisplayState
}

/// 读快照 JSON → WidgetTimelineBuilder 预生成时间线（纯本地计算，无网络）。
/// 快照缺失/解码失败 → 空态 entry（spec「快照缺失回退」，不崩溃）。
struct CourseTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> CourseEntry {
        CourseEntry(date: Date(), state: WidgetDisplayState(
            showsTomorrow: false, weekNumber: nil, courses: [], emptyMessage: "今天没有课"
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (CourseEntry) -> Void) {
        completion(currentEntry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CourseEntry>) -> Void) {
        let entries = WidgetTimelineBuilder.build(snapshot: readSnapshot(), date: Date())
            .map { CourseEntry(date: $0.date, state: $0.state) }
        // .atEnd：末 entry 展示完毕后系统请求新时间线（app 侧变化亦主动 reload）
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func currentEntry(at date: Date) -> CourseEntry {
        let entries = WidgetTimelineBuilder.build(snapshot: readSnapshot(), date: date)
        return CourseEntry(date: date, state: entries.first?.state ?? WidgetDisplayState(
            showsTomorrow: false, weekNumber: nil, courses: [], emptyMessage: "今天没有课"
        ))
    }

    private func readSnapshot() -> WidgetSnapshot? {
        guard let container = WidgetSettingsReader.containerURL else { return nil }
        return WidgetSnapshot.read(from: WidgetSnapshot.snapshotURL(containerURL: container))
    }
}

// MARK: - 设置读取（App Group）

enum WidgetSettingsReader {
    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSharedKeys.appGroupId
        )
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: WidgetSharedKeys.appGroupId)
    }

    /// 背景图（容器内绝对路径）；文件缺失回退 nil（纯色背景）。
    static func backgroundImageURL() -> URL? {
        guard let defaults,
              let relative = defaults.string(forKey: WidgetSharedKeys.backgroundPathKey),
              !relative.isEmpty,
              let container = containerURL else {
            return nil
        }
        let url = container.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func backgroundOpacity() -> Double {
        let value = defaults?.double(forKey: WidgetSharedKeys.backgroundOpacityKey)
        return (value == 0 && defaults?.object(forKey: WidgetSharedKeys.backgroundOpacityKey) == nil)
            ? WidgetSharedKeys.defaultOpacity
            : min(max(value ?? WidgetSharedKeys.defaultOpacity, 0), 1)
    }
}
