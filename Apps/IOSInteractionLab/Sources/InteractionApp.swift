import SwiftUI

#if !targetEnvironment(simulator)
#error("This offline interaction prototype is for iOS Simulator only.")
#endif

@main
struct InteractionApp: App {
    var body: some Scene { WindowGroup { InteractionWorkspace() } }
}

private enum DemoWindow: String, CaseIterable, Identifiable {
    case browser = "浏览器", document = "文档", editor = "编辑器"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .browser: return CGSize(width: 1280, height: 720)
        case .document: return CGSize(width: 720, height: 1000)
        case .editor: return CGSize(width: 1440, height: 900)
        }
    }
}

struct InteractionWorkspace: View {
    @State private var window = DemoWindow.browser
    @StateObject private var interaction = MobileInteractionSession(localInputPreview: true)
    @StateObject private var textSession = MobileTextSession()
    @State private var committed = ""
    @State private var keyboard = false
    @State private var windowPicker = false
    @State private var dragPosition = CGPoint(x: 640, y: 360)
    @State private var draggingObject = false
    @State private var scrollOffset: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("KKRemote").font(.headline)
                    Text("离线交互原型 · 未连接主机").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { textSession.cancel(); interaction.invalidate(); windowPicker = true } label: {
                    Label(window.rawValue, systemImage: "macwindow.on.rectangle")
                }.accessibilityIdentifier("chooseWindow")
            }.padding(.horizontal, 16).padding(.vertical, 10)
            MobileViewport(session: interaction, source: window.size, target: window.id) {
                demoContent.accessibilityHidden(true)
            }
            VStack(spacing: 8) {
                HStack {
                    Text(interaction.status).font(.caption.monospacedDigit()).accessibilityIdentifier("coordinateStatus")
                    Spacer()
                    Text("\(Int((interaction.zoom * 100).rounded()))%").font(.caption.monospacedDigit()).accessibilityIdentifier("zoomValue")
                }
                HStack(spacing: 8) {
                    Button { interaction.toggleMode() } label: {
                        Label(interaction.relative ? "触控板" : "触控", systemImage: interaction.relative ? "cursorarrow" : "hand.tap")
                    }.accessibilityIdentifier("inputMode")
                    Button { interaction.toggleInspection() } label: {
                        Image(systemName: interaction.inspect ? "hand.draw.fill" : "hand.draw")
                    }.accessibilityLabel(interaction.inspect ? "返回操控" : "平移画面").accessibilityIdentifier("inspectMode")
                    Spacer(minLength: 0)
                    Button { interaction.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                        .accessibilityLabel("放大").accessibilityIdentifier("zoomIn")
                    Button { interaction.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("完整显示").accessibilityIdentifier("fitWindow")
                    Button {
                        interaction.invalidate(); keyboard.toggle()
                        if keyboard { textSession.focused = true } else { textSession.cancel() }
                    } label: { Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard") }
                        .accessibilityLabel(keyboard ? "收起键盘" : "输入文字").accessibilityIdentifier("toggleKeyboard")
                }.buttonStyle(.bordered).font(.subheadline)
                if keyboard { MobileTextComposer(session: textSession) }
                HStack {
                    Text(interaction.inspect ? "平移查看 · 双指缩放" : "长按后拖动 · 双指滚动 · 捏合缩放")
                    Spacer()
                    Text("滚动 \(Int(scrollOffset))").accessibilityIdentifier("scrollStatus")
                }.font(.caption2).foregroundStyle(.secondary)
                Text(committed.isEmpty ? "尚未发送文字" : committed)
                    .font(.caption).lineLimit(2).accessibilityIdentifier("committedText")
            }.padding(12).background(.regularMaterial)
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $windowPicker) {
            NavigationStack {
                List(DemoWindow.allCases) { item in
                    Button {
                        window = item; committed = ""; textSession.cancel(); keyboard = false
                        interaction.invalidate(); interaction.fit()
                        dragPosition = CGPoint(x: item.size.width / 2, y: item.size.height / 2)
                        draggingObject = false; scrollOffset = 0; windowPicker = false
                    } label: {
                        HStack {
                            Label(item.rawValue, systemImage: "macwindow")
                            Spacer()
                            Text("\(Int(item.size.width)) × \(Int(item.size.height))").foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("window-\(item.id)")
                }.navigationTitle("模拟窗口")
                    .toolbar { Button("完成") { windowPicker = false } }
            }.presentationDetents([.medium, .large])
        }
        .onAppear {
            textSession.onCommit = { text, id in interaction.commit(text, id: id) }
            interaction.onEvent = { event in
                switch event {
                case .buttonDown:
                    if let pointer = interaction.pointer {
                        draggingObject = abs(pointer.x - dragPosition.x) < 100 && abs(pointer.y - dragPosition.y) < 32
                    }
                case .buttonUp, .cancel: draggingObject = false
                case let .move(point): if draggingObject { dragPosition = point }
                case let .scroll(delta): scrollOffset += delta.height
                case let .text(text, _): committed += text
                default: break
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { textSession.cancel(); interaction.invalidate(); draggingObject = false }
        }
    }

    private var demoContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in Circle().fill(color).frame(width: 14, height: 14) }
                Spacer()
                Text("\(window.rawValue) · \(Int(window.size.width)) × \(Int(window.size.height)) 点").font(.system(size: 18, weight: .medium))
                Spacer()
            }.padding(20).background(Color(uiColor: .tertiarySystemBackground))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 24) {
                    Label("工作区", systemImage: "square.grid.2x2").font(.system(size: 22, weight: .bold))
                    Text("概览").foregroundStyle(.blue)
                    Text("最近打开")
                    Text("收藏")
                    Spacer()
                    Text("左下角").font(.system(size: 16))
                }.font(.system(size: 20)).padding(24).frame(width: 200).background(Color.blue.opacity(0.06))
                VStack(alignment: .leading, spacing: 28) {
                    Text(window == .document ? "把桌面带到手边" : "你的远程工作区").font(.system(size: 42, weight: .bold))
                    Text("完整保留窗口内容，让每一次点击都有准确的位置。")
                        .font(.system(size: 24)).foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        demoCard("窗口比例", value: "\(Int(window.size.width)) : \(Int(window.size.height))")
                        demoCard("输入方式", value: "触控 / 触控板")
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("文字提交预览").font(.system(size: 20, weight: .semibold))
                        Text(committed.isEmpty ? "打开底部键盘，试着输入一段文字。" : committed)
                            .font(.system(size: 26)).foregroundStyle(committed.isEmpty ? .secondary : .primary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                    Spacer(minLength: 0)
                    HStack { Text("本地示例画面"); Spacer(); Text("右下角") }.font(.system(size: 16)).foregroundStyle(.secondary)
                }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.background(Color(uiColor: .systemBackground))
            .overlay(alignment: .topLeading) {
                Text("长按拖动此卡片").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white).frame(width: 200, height: 64)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                    .position(dragPosition)
            }
            .overlay { Rectangle().strokeBorder(Color.blue.opacity(0.6), lineWidth: 2) }
    }
    private func demoCard(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 18)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold))
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
