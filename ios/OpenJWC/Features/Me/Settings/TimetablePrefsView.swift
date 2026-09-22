import SwiftUI
import OpenJWCCore

/// 课表显示设置（tasks 8.2）：四开关（读写 UserSettings，默认全开）+ 迷你课表预览实时反映。
struct TimetablePrefsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var showTimeline = true
    @State private var showDate = true
    @State private var showPeriodTime = true
    @State private var showNonCurrentWeek = true

    var body: some View {
        Form {
            Section("预览") {
                TimetableMiniPreview(prefs: (showTimeline, showDate, showPeriodTime, showNonCurrentWeek))
                    .frame(height: 210)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                Toggle("时间指示线", isOn: $showTimeline)
                Toggle("日期表头", isOn: $showDate)
                Toggle("节次时间", isOn: $showPeriodTime)
                Toggle("显示非本周课程", isOn: $showNonCurrentWeek)
            } footer: {
                Text("开关即时生效，对课程表 tab 与上方预览同步应用。")
            }
        }
        .navigationTitle("课表设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let user = environment.settings.loadUserSettings()
            showTimeline = user.showTimeline
            showDate = user.showDate
            showPeriodTime = user.showPeriodTime
            showNonCurrentWeek = user.showNonCurrentWeek
        }
        .onChange(of: showTimeline) { save() }
        .onChange(of: showDate) { save() }
        .onChange(of: showPeriodTime) { save() }
        .onChange(of: showNonCurrentWeek) { save() }
    }

    private func save() {
        var user = environment.settings.loadUserSettings()
        user.showTimeline = showTimeline
        user.showDate = showDate
        user.showPeriodTime = showPeriodTime
        user.showNonCurrentWeek = showNonCurrentWeek
        environment.settings.saveUserSettings(user)
        environment.timetable.reloadPrefs()
    }
}

// MARK: - 迷你课表预览

/// 固定示例数据的迷你网格（5 天 × 4 节），四开关实时反映展示效果。
struct TimetableMiniPreview: View {
    let prefs: (timeline: Bool, date: Bool, periodTime: Bool, nonCurrentWeek: Bool)

    private let periodHeight: CGFloat = 40
    private let dayLabels = ["周一", "周二", "周三", "周四", "周五"]
    private let dateLabels = ["9/22", "9/23", "9/24", "9/25", "9/26"]
    private let periodTimes = [("08:00", "08:45"), ("08:50", "09:35"), ("09:50", "10:35"), ("10:40", "11:25")]

    var body: some View {
        GeometryReader { proxy in
            let timeWidth: CGFloat = 34
            let colWidth = (proxy.size.width - timeWidth) / 5
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: timeWidth, height: 26)
                    ForEach(0..<5, id: \.self) { i in
                        VStack(spacing: 1) {
                            Text(dayLabels[i]).font(.system(size: 9, weight: .medium))
                            if prefs.date {
                                Text(dateLabels[i]).font(.system(size: 7)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: colWidth, height: 26)
                    }
                }
                .frame(height: 26)

                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let grid = Color.secondary.opacity(0.25)
                        for i in 0...4 {
                            let y = CGFloat(i) * periodHeight
                            context.stroke(Path { p in
                                p.move(to: CGPoint(x: timeWidth, y: y))
                                p.addLine(to: CGPoint(x: size.width, y: y))
                            }, with: .color(grid), lineWidth: 0.5)
                        }
                        for i in 0...5 {
                            let x = timeWidth + CGFloat(i) * colWidth
                            context.stroke(Path { p in
                                p.move(to: CGPoint(x: x, y: 0))
                                p.addLine(to: CGPoint(x: x, y: size.height))
                            }, with: .color(grid), lineWidth: 0.5)
                        }
                    }

                    // 节次标签列
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { i in
                            VStack(spacing: 1) {
                                Text("\(i + 1)").font(.system(size: 8, weight: .medium))
                                if prefs.periodTime {
                                    Text(periodTimes[i].0).font(.system(size: 6))
                                    Text(periodTimes[i].1).font(.system(size: 6))
                                }
                            }
                            .foregroundStyle(.secondary)
                            .frame(width: timeWidth, height: periodHeight)
                        }
                    }

                    // 本周课程块（周二第 2 节 ×2）
                    miniBlock(name: "软件工程", teacher: "李老师", place: "机房",
                              column: 1, row: 1, colWidth: colWidth)

                    // 非本周课程块（周四第 3 节，按开关淡显）
                    if prefs.nonCurrentWeek {
                        miniBlock(name: "大学物理", teacher: "张老师", place: "教一-101",
                                  column: 3, row: 2, colWidth: colWidth, isOtherWeek: true)
                    }

                    if prefs.timeline {
                        let y = periodHeight * 1.5
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.accentColor).frame(height: 1.5)
                            Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(x: -2.5)
                        }
                        .frame(width: proxy.size.width - timeWidth, height: 1.5)
                        .offset(x: timeWidth, y: y)
                    }
                }
            }
        }
    }

    private func miniBlock(
        name: String, teacher: String, place: String,
        column: Int, row: Int, colWidth: CGFloat, isOtherWeek: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.system(size: 9, weight: .semibold)).lineLimit(1)
            Text(teacher).font(.system(size: 7)).lineLimit(1)
            Text("@\(place)").font(.system(size: 7)).lineLimit(1)
        }
        .foregroundStyle(isOtherWeek ? Color.secondary : Color.courseContent(0xFF283593, dark: false))
        .padding(3)
        .frame(width: colWidth - 4, height: periodHeight * 2 - 4, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(
                isOtherWeek ? Color.secondary.opacity(0.12) : Color.courseContainer(0xFF283593, dark: false)
            )
        }
        .offset(x: 34 + CGFloat(column) * colWidth + 2, y: CGFloat(row) * periodHeight + 2)
    }
}
