#if os(iOS) && targetEnvironment(simulator)
import SwiftUI

/// Simulator fixture only. Reflow represents a future acknowledged Host resize;
/// it is not a video stream, a captured desktop or proof of Host resize support.
struct IPhoneOfflineWorkspace: View {
    let close: () -> Void
    @StateObject private var interaction = MobileInteractionSession(localInputPreview: true, directScroll: true)
    @StateObject private var text = MobileTextSession()
    @State private var selected = 0
    @State private var windows = false
    @State private var notes = ["", ""]
    @State private var completed = [false, false]
    @State private var scroll: CGFloat = 0
    @State private var checkBounds = CGRect.zero
    @State private var noteBounds = CGRect.zero
    private let titles = ["旅行计划", "阅读清单"]

    var body: some View {
        IPhoneWindowWorkspace(title: titles[selected], subtitle: "离线预览 · 随 iPhone 工作区排版",
            symbol: selected == 0 ? "note.text" : "book.closed", target: "preview-\(selected)",
            hasWindow: true, canChooseWindow: true, interaction: interaction, text: text,
            chooseWindow: { windows = true }) {
                Button("结束预览", systemImage: "xmark.circle", action: close)
            } content: {
                GeometryReader { proxy in
                    // Match the local fixture to the available viewport. The
                    // production viewer preserves the received frame's ratio.
                    let source = CGSize(width: max(1, proxy.size.width) * 1.5, height: max(1, proxy.size.height) * 1.5)
                    MobileViewport(session: interaction, source: source, target: "preview-\(selected)") {
                        document(size: source)
                    }
                }
            }
            .sheet(isPresented: $windows) { windowPicker.presentationDetents([.medium, .large]) }
            .onAppear {
                text.onCommit = { value, id in interaction.commit(value, id: id) }
                interaction.onEvent = { event in
                    switch event {
                    case let .text(value, _): notes[selected] += value
                    case .buttonUp:
                        if !interaction.isDragging, let point = interaction.pointer,
                           checkBounds.contains(CGPoint(x: point.x, y: point.y - documentOffset(size: interaction.source))) {
                            completed[selected].toggle()
                        }
                    case let .scroll(delta): scroll = min(0, max(-300, scroll + delta.height))
                    default: break
                    }
                }
            }
            .onChange(of: selected) { _, _ in scroll = 0 }
    }

    private func document(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemBackground)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: selected == 0 ? "folder" : "books.vertical")
                    Text(selected == 0 ? "个人备忘录" : "我的收藏")
                    Spacer()
                    Image(systemName: "square.and.pencil")
                }.font(.system(size: 20)).foregroundStyle(.secondary).frame(height: 64)
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    Text(selected == 0 ? "周末，去山里走走。" : "留一点时间给阅读。")
                        .font(.system(size: 36, weight: .bold)).lineLimit(2)
                    Text(selected == 0 ? "把想做的事，放在手边。" : "好文章，慢慢读。")
                        .font(.system(size: 24)).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Image(systemName: completed[selected] ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(completed[selected] ? Color.blue : Color.secondary)
                        Text(selected == 0 ? "整理行李和相机" : "读完今天的一章")
                            .strikethrough(completed[selected])
                    }.font(.system(size: 26)).frame(height: 68).frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: PreviewCheckBounds.self, value: proxy.frame(in: .named("previewDocument")))
                            }
                        }
                    Divider()
                    Text("随手记").font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary)
                    Text(notes[selected].isEmpty ? "点下方键盘，记下新的想法…" : notes[selected])
                        .font(.system(size: 28)).foregroundStyle(notes[selected].isEmpty ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: PreviewNoteBounds.self, value: proxy.frame(in: .named("previewDocument")))
                            }
                        }
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left")
                        Text("点击勾选 · 单指滚动 · 捏合放大")
                    }.font(.system(size: 18)).foregroundStyle(.tertiary)
                }.padding(.top, 30)
                Spacer(minLength: 24)
            }.fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
                .coordinateSpace(name: "previewDocument")
                .offset(y: documentOffset(size: size))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onPreferenceChange(PreviewCheckBounds.self) { checkBounds = $0 }
        .onPreferenceChange(PreviewNoteBounds.self) { noteBounds = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notes[selected].isEmpty ? "尚未输入" : notes[selected])
        .accessibilityValue(completed[selected] ? "已勾选" : "未勾选")
        .accessibilityIdentifier("phoneDocument")
    }

    private func documentOffset(size: CGSize) -> CGFloat {
        scroll - (text.focused ? max(0, noteBounds.maxY - size.height + 24) : 0)
    }

    private var windowPicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(0..<titles.count, id: \.self) { index in
                        Button {
                            interaction.invalidate(); text.cancel(); selected = index; windows = false
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: index == 0 ? "note.text" : "book.closed")
                                    .font(.title2).foregroundStyle(.tint).frame(width: 44, height: 52)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(titles[index]).font(.headline)
                                    Text(index == 0 ? "备忘录" : "阅读").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected == index { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("phoneWindow-\(index)")
                    }
                } header: { Text("本地示例窗口") }
                  footer: { Text("用于预览手机交互，不连接主机。") }
            }.navigationTitle("切换窗口").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { windows = false } } }
        }
    }
}

private struct PreviewCheckBounds: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
private struct PreviewNoteBounds: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
#endif
