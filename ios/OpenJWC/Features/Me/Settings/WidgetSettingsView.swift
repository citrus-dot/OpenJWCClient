import SwiftUI
import PhotosUI
import WidgetKit
import OpenJWCCore

/// 小组件设置页（design D-8，spec「小组件设置页」Requirement）：
/// 实时预览（静态示例数据 + 背景图/不透明度）+ 选图（降采样重编码红线 3）+ 移除背景 + 不透明度滑块。
/// 任一变更写入 App Group defaults 并触发小组件刷新（11.3 链路）。
struct WidgetSettingsView: View {
    @State private var backgroundImage: UIImage?
    @State private var hasBackground = false
    @State private var opacity = WidgetSharedKeys.defaultOpacity
    @State private var pickerItem: PhotosPickerItem?
    @State private var loadError: String?

    var body: some View {
        List {
            Section("预览") {
                WidgetPreview(backgroundImage: backgroundImage, opacity: opacity)
                    .frame(height: 155)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            Section {
                PhotosPicker(
                    selection: $pickerItem,
                    matching: .images,
                    preferredItemEncoding: .compatible
                ) {
                    Label("选择图片", systemImage: "photo")
                }
                if hasBackground {
                    Button(role: .destructive) {
                        removeBackground()
                    } label: {
                        Label("移除背景", systemImage: "trash")
                    }
                }
            } header: {
                Text("背景图片")
            } footer: {
                Text("图片会自动压缩后存入小组件共享容器（原图直接使用会导致小组件内存不足）。")
            }

            Section {
                HStack {
                    Slider(
                        value: Binding(
                            get: { opacity },
                            set: { newValue in
                                opacity = newValue
                                saveOpacity(newValue)
                            }
                        ),
                        in: 0...1
                    )
                    Text("\(Int(opacity * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            } header: {
                Text("背景不透明度")
            } footer: {
                Text("0% 完全透明（只剩文字），100% 背景完全不透明。")
            }
        }
        .navigationTitle("小组件")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadCurrent() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await handlePicked(item) }
            pickerItem = nil
        }
        .alert("图片处理失败", isPresented: Binding(
            get: { loadError != nil },
            set: { if !$0 { loadError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(loadError ?? "")
        }
    }

    // MARK: - 读 / 写（App Group 容器 + defaults）

    private var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSharedKeys.appGroupId
        )
    }

    private func loadCurrent() {
        if let url = backgroundFileURL(), let image = UIImage(contentsOfFile: url.path) {
            backgroundImage = image
            hasBackground = true
        } else {
            backgroundImage = nil
            hasBackground = false
        }
        if let defaults = UserDefaults(suiteName: WidgetSharedKeys.appGroupId),
           defaults.object(forKey: WidgetSharedKeys.backgroundOpacityKey) != nil {
            opacity = min(max(defaults.double(forKey: WidgetSharedKeys.backgroundOpacityKey), 0), 1)
        } else {
            opacity = WidgetSharedKeys.defaultOpacity
        }
    }

    private func backgroundFileURL() -> URL? {
        guard let container = containerURL else { return nil }
        let url = container.appendingPathComponent(WidgetSharedKeys.backgroundFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 选图 → 降采样 ≤1280px + 重编码 JPEG q≈0.75（红线 3）→ 写容器 → 记路径键 → 刷新。
    private func handlePicked(_ item: PhotosPickerItem) async {
        guard let container = containerURL else {
            loadError = "无法访问共享容器"
            return
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            loadError = "无法读取所选图片"
            return
        }
        guard let encoded = WidgetImageProcessor.downsampleAndEncode(imageData: data) else {
            loadError = "图片格式不支持"
            return
        }
        let target = container.appendingPathComponent(WidgetSharedKeys.backgroundFileName)
        do {
            try encoded.write(to: target, options: .atomic)
        } catch {
            loadError = error.localizedDescription
            return
        }
        UserDefaults(suiteName: WidgetSharedKeys.appGroupId)?
            .set(WidgetSharedKeys.backgroundFileName, forKey: WidgetSharedKeys.backgroundPathKey)
        loadCurrent()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedKeys.widgetKind)
    }

    private func removeBackground() {
        try? FileManager.default.removeItem(at: backgroundFileURL() ?? URL(fileURLWithPath: "/dev/null"))
        UserDefaults(suiteName: WidgetSharedKeys.appGroupId)?
            .set("", forKey: WidgetSharedKeys.backgroundPathKey)
        loadCurrent()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedKeys.widgetKind)
    }

    private func saveOpacity(_ value: Double) {
        UserDefaults(suiteName: WidgetSharedKeys.appGroupId)?
            .set(value, forKey: WidgetSharedKeys.backgroundOpacityKey)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedKeys.widgetKind)
    }
}

// MARK: - 预览（静态示例数据，实时反映背景/不透明度；型同 Android WidgetSettingsScreen）

private struct WidgetPreview: View {
    let backgroundImage: UIImage?
    let opacity: Double

    /// 静态示例（对齐 Android：周四 / 第 13 周 / 两门示例课）。
    private static let sampleCourses: [(name: String, time: String, meta: String, color: Color)] = [
        ("数据结构", "10:00", "第3-4节 | 教三-301 | 王老师", .blue),
        ("大学英语", "14:00", "第5-6节 | 教二-108 | 李老师", .orange),
    ]

    var body: some View {
        ZStack {
            Group {
                if let backgroundImage {
                    Image(uiImage: backgroundImage)
                        .resizable()
                        .scaledToFill()
                        .opacity(opacity)
                } else {
                    Color(.systemGray5)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("今天 · 星期四", systemImage: "tablecells")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("第 13 周")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                ForEach(Self.sampleCourses, id: \.name) { course in
                    HStack(spacing: 8) {
                        Text(course.time)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(course.color)
                            .frame(width: 3.5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(course.name)
                                .font(.footnote.weight(.semibold))
                            Text(course.meta)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
    }
}
