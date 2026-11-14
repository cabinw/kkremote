#if os(iOS)
import SwiftUI

/// Content is the application. Session controls live in one small floating menu,
/// rather than permanently consuming the application's top and bottom edges.
struct IPhoneWindowWorkspace<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let target: String
    let hasWindow: Bool
    let canChooseWindow: Bool
    @ObservedObject var interaction: MobileInteractionSession
    @ObservedObject var text: MobileTextSession
    var inlineInput = false
    var directKeyboard = false
    var onKeyboardFocus:()->Void = {}
    var onKeyboardText:(String)->Void = { _ in }
    var onKeyboardKey:(String)->Void = { _ in }
    var canEnterText = true
    var submittingText = false
    var textContext: String? = nil
    var edgeColor = WindowEdgeColor.initial
    let chooseWindow: () -> Void
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    @State private var keyboard = false
    @State private var dockOffset = CGSize.zero
    @State private var dockDragStart = CGSize.zero
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
        content()
            .frame(maxWidth:.infinity,maxHeight:.infinity).clipped()
            .overlay(alignment:.bottomTrailing) {
                if directKeyboard || !text.focused {
                    HStack(spacing:0) {
                    if interaction.inputEnabled && !inlineInput {
                        Button { if directKeyboard && text.focused { endInput() } else { interaction.invalidate();keyboard=true;text.focused=true } } label: {
                            Image(systemName:directKeyboard && text.focused ? "keyboard.chevron.compact.down":"keyboard").frame(width:52,height:48)
                        }.disabled(!hasWindow || !canEnterText).accessibilityLabel(directKeyboard && text.focused ? "隐藏键盘":"键盘").accessibilityIdentifier("phoneKeyboard")
                        Divider().frame(height:22)
                    }
                    Button { endInput();chooseWindow() } label: {
                        Image(systemName:"macwindow.on.rectangle").frame(width:52,height:48)
                    }.disabled(!canChooseWindow).accessibilityLabel("选择窗口").accessibilityIdentifier("phoneChooseWindow")
                    Divider().frame(height:22)
                    Menu {
                        Section {
                            Button("切换窗口",systemImage:"macwindow.on.rectangle") { endInput(); chooseWindow() }
                                .disabled(!canChooseWindow).accessibilityIdentifier("phoneWindows")
                            if !interaction.locksWholeWindow {
                            Button("自动铺满",systemImage:"arrow.up.left.and.arrow.down.right") { interaction.setFillsViewport(true) }
                                .disabled(!hasWindow).accessibilityIdentifier("phoneFill")
                            Button("显示完整窗口",systemImage:"macwindow") { interaction.setFillsViewport(false) }
                                .disabled(!hasWindow).accessibilityIdentifier("phoneFit")
                            Button("放大画面",systemImage:"plus.magnifyingglass") { interaction.zoomIn() }.disabled(!hasWindow)
                            }
                            if interaction.inputEnabled {
                            Button(interaction.relative ? "切换为触摸" : "切换为触控板",systemImage:"cursorarrow") { interaction.toggleMode() }
                                .disabled(!interaction.inputEnabled || !hasWindow).accessibilityIdentifier("phoneInputMode")
                            }
                            if interaction.localInputPreview {
                                Button(interaction.inspect ? "返回触摸操控" : "平移画面",systemImage:"hand.draw") { interaction.toggleInspection() }.disabled(!hasWindow)
                            }
                        } header: { Text(title) }
                        actions()
                    } label: {
                        Image(systemName:"ellipsis").font(.system(size:18,weight:.semibold))
                            .foregroundStyle(.primary).frame(width:52,height:48)
                    }.accessibilityLabel("窗口工具").accessibilityValue(title).accessibilityIdentifier("phoneMenu")
                    }
                    .buttonStyle(.plain).background(.regularMaterial,in:Capsule())
                    .overlay(Capsule().stroke(.primary.opacity(0.08),lineWidth:0.5))
                    .shadow(color:.black.opacity(0.12),radius:10,y:3)
                    .offset(dockOffset)
                    .highPriorityGesture(DragGesture(minimumDistance:10,coordinateSpace:.global)
                        .onChanged { value in
                            dockOffset = CGSize(width:min(0,max(-max(0,proxy.size.width-(interaction.inputEnabled ? 188:136)),dockDragStart.width+value.translation.width)),
                                height:min(0,max(-max(0,proxy.size.height-112),dockDragStart.height+value.translation.height)))
                        }.onEnded { _ in dockDragStart = dockOffset })
                    .padding(.trailing,12).padding(.bottom,text.focused ? 20:max(20,proxy.safeAreaInsets.bottom+8))
                }
            }
            .safeAreaInset(edge:.bottom,spacing:0) {
                if keyboard && !inlineInput && !directKeyboard {
                    VStack(spacing:4) {
                        if let textContext { Text(textContext).font(.caption).foregroundStyle(.secondary) }
                        MobileTextComposer(session:text,compact:true,showHint:true,submitting:submittingText)
                    }.padding(12).background(.regularMaterial)
                }
            }
            .background(alignment:.topLeading) {
                if directKeyboard {
                    RemoteKeyboardCapture(session:text,onText:onKeyboardText,onKey:onKeyboardKey)
                        .frame(width:1,height:1).clipped()
                }
            }
            .onChange(of:proxy.size) { _,_ in dockOffset = .zero;dockDragStart = .zero }
        }
            .ignoresSafeArea(.container,edges:.bottom)
            .background {
                Color(.sRGB,red:edgeColor.red,green:edgeColor.green,blue:edgeColor.blue,opacity:1).ignoresSafeArea()
            }
            .preferredColorScheme(edgeColor.prefersLightContent ? .dark : .light)
            .onChange(of:target) { _,_ in endInput(); interaction.fit() }
            .onChange(of:hasWindow) { _,available in if !available { endInput() } }
            .onChange(of:text.focused) { _,focused in interaction.setKeyboardPresented(focused);if focused && directKeyboard { onKeyboardFocus() };if !focused { keyboard = false } }
            .onChange(of:scenePhase) { _,phase in if phase != .active { endInput() } }
            .onDisappear { endInput() }
    }
    private func endInput() { interaction.setKeyboardPresented(false);text.cancel(); keyboard = false; interaction.invalidate() }
}
#endif
