import SwiftUI

struct RemoteWindowControls: View {
    @ObservedObject var model: LabModel
    @State private var showingWindows = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedRemoteWindow?.label ?? (model.track == nil ? "远端窗口" : "主机默认画面"))
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                Text(model.windowBusy ? "正在切换…" : (model.windowSupported ? model.windowStatus :
                    (model.running ? "等待主机窗口目录支持" : "连接后选择窗口")))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                showingWindows = true
                model.refreshRemoteWindows()
            } label: { Label("窗口", systemImage: "macwindow.on.rectangle") }
                .buttonStyle(.bordered).font(.subheadline)
                .disabled(!model.running || !model.windowSupported || model.windowBusy)
                .accessibilityLabel("选择远端窗口")
        }
        .sheet(isPresented: $showingWindows) {
            RemoteWindowsView(model: model) { showingWindows = false }
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 440)
                #endif
        }
    }
}

struct RemoteWindowsView: View {
    @ObservedObject var model: LabModel
    let dismiss: () -> Void
    @State private var search = ""
    private var filteredWindows: [RemoteWindow] {
        model.remoteWindows.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let error = model.windowError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if model.catalogLoading {
                        HStack { ProgressView(); Text("正在读取主机窗口…") }
                    } else if model.remoteWindows.isEmpty {
                        Text("没有可捕获窗口。请在 Mac 打开应用窗口后刷新，并检查屏幕录制权限。")
                            .foregroundStyle(.secondary)
                    } else if filteredWindows.isEmpty {
                        Text("没有匹配的窗口，请更换搜索词。").foregroundStyle(.secondary)
                    }
                    ForEach(filteredWindows) { window in
                        Button {
                            model.selectRemoteWindow(window)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "macwindow").font(.title2).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(window.application).font(.headline)
                                    Text(window.title.isEmpty ? "无标题窗口" : window.title)
                                        .font(.subheadline).lineLimit(2)
                                    Text("\(Int(window.widthPoints)) × \(Int(window.heightPoints)) 点")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selectedRemoteWindow?.number == window.number &&
                                    model.selectedRemoteWindow?.processID == window.processID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                } else { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.windowBusy || model.catalogLoading)
                            .accessibilityIdentifier("remoteWindowRow-\(window.number)")
                    }
                } header: { Text("主机上的应用窗口") }
                  footer: { Text(model.windowControlSupported ? "点击选择窗口后可触控；单指滑动滚动，打开键盘可直接输入到桌面当前焦点。":"当前主机仅支持观看和切换窗口。") }
                if model.selectedRemoteWindow != nil {
                    Section {
                        Button("停止观看，保留连接") { model.selectRemoteWindow(nil); dismiss() }
                            .disabled(model.windowBusy || model.catalogLoading)
                    } footer: { Text("停止观看不会关闭 Mac 上的应用或窗口。") }
                }
            }
            .navigationTitle("远端窗口")
            .searchable(text: $search, prompt: "应用或窗口标题")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: dismiss) }
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新", systemImage: "arrow.clockwise") { model.refreshRemoteWindows() }
                        .disabled(model.catalogLoading || model.windowBusy || !model.running)
                }
            }
        }
    }
}
