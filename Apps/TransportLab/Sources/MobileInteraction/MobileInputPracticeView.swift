#if os(iOS)
import SwiftUI

/// A local exercise for the same components used around the stream. It has no
/// LabModel reference, connection settings or network-capable callback.
struct MobileInputPracticeView: View {
    @StateObject private var interaction = MobileInteractionSession(localInputPreview: true)
    @StateObject private var text = MobileTextSession()
    @State private var submitted = ""
    @State private var keyboard = false
    @State private var card = CGPoint(x: 480, y: 320)
    @State private var draggingCard = false
    @State private var scroll: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    private let source = CGSize(width: 960, height: 640)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("本地练习，不向主机发送操作").font(.caption).foregroundStyle(.secondary).padding(8)
                MobileViewport(session: interaction, source: source, target: "local-practice") {
                    ZStack(alignment: .topLeading) {
                        Color(uiColor: .systemBackground)
                        VStack(alignment: .leading, spacing: 20) {
                            Text("触摸与中文输入").font(.system(size: 40, weight: .bold))
                            Text("长按卡片后拖动；双指滚动；捏合缩放。")
                            Text("滚动位置：\(Int(scroll))")
                            Text(submitted.isEmpty ? "打开键盘，选择中文候选词后发送。" : submitted)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }.font(.system(size: 24)).padding(36)
                        Text("拖动我").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 180, height: 64).background(.blue, in: RoundedRectangle(cornerRadius: 12)).position(card)
                    }.accessibilityHidden(true)
                }
                VStack(spacing: 8) {
                    Text(interaction.status).font(.caption).accessibilityIdentifier("practiceStatus")
                    HStack {
                        Button(interaction.relative ? "触控板" : "触控") { interaction.toggleMode() }
                            .accessibilityIdentifier("practiceMode")
                        Button(interaction.inspect ? "操控" : "平移") { interaction.toggleInspection() }
                        Button("复位") { interaction.fit() }.accessibilityIdentifier("practiceFit")
                        Spacer(minLength: 0)
                        Button("键盘") {
                            interaction.invalidate(); keyboard.toggle()
                            if keyboard { text.focused = true } else { text.cancel() }
                        }.accessibilityIdentifier("practiceKeyboard")
                    }.buttonStyle(.bordered)
                    if keyboard { MobileTextComposer(session: text) }
                    Text(submitted.isEmpty ? "尚未发送文字" : submitted).font(.caption).lineLimit(3)
                        .accessibilityIdentifier("practiceCommitted")
                }.padding(12).background(.regularMaterial)
            }.navigationTitle("离线交互练习").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { text.cancel(); interaction.invalidate(); dismiss() } }
                }
        }
        .onAppear {
            text.onCommit = { value, id in interaction.commit(value, id: id) }
            interaction.onEvent = { event in
                switch event {
                case .buttonDown:
                    if let p = interaction.pointer { draggingCard = abs(p.x - card.x) < 90 && abs(p.y - card.y) < 32 }
                case .buttonUp, .cancel: draggingCard = false
                case let .move(point): if draggingCard { card = point }
                case let .scroll(delta): scroll += delta.height
                case let .text(value, _): submitted += value
                default: break
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { text.cancel(); interaction.invalidate() } }
        .onDisappear { text.cancel(); interaction.invalidate() }
    }
}
#endif
