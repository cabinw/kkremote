#if os(iOS) && targetEnvironment(simulator)
import SwiftUI

struct WPSWorkspace:View {
    @StateObject private var remote=WPSRemoteSession()
    @StateObject private var interaction=MobileInteractionSession(localInputPreview:true,directScroll:true,fillsViewport:true)
    @StateObject private var text=MobileTextSession()
    @State private var available=CGSize.zero
    @State private var dockOffset=CGSize.zero
    @State private var dockDragStart=CGSize.zero
    @Environment(\.scenePhase) private var phase
    var body:some View {
        GeometryReader { proxy in
            ZStack(alignment:.topLeading) {
                edgeBackground
                if let track=remote.track {
                    MobileViewport(session:interaction,source:remote.source,target:"wps-\(remote.state?.version ?? 0)",focusRect:focusRect,background:edgeBackground) {
                        // Remove only the encoder canvas padding, before applying the shared display/hit-test transform.
                        let scale=min(CGFloat(remote.state?.videoWidth ?? 1)/remote.source.width,CGFloat(remote.state?.videoHeight ?? 1)/remote.source.height)
                        ColorManagedVideo(track:track)
                            .frame(width:CGFloat(remote.state?.videoWidth ?? 1)/scale,height:CGFloat(remote.state?.videoHeight ?? 1)/scale)
                            .frame(width:remote.source.width,height:remote.source.height,alignment:.topLeading).clipped()
                    }
                    .frame(height:max(1,proxy.size.height-(text.focused ? 76 : 0)))
                    .allowsHitTesting(remote.ready && !text.focused && !remote.pendingCommit)
                }
                if !remote.ready && remote.error==nil {
                    ProgressView("正在适配 WPS 窗口…").padding(16)
                        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }
            .overlay(alignment:.bottomTrailing) {
                if text.focused {
                    editor.padding(12)
                } else {
                    floatingTools
                        .offset(dockOffset)
                        .highPriorityGesture(DragGesture(minimumDistance:10,coordinateSpace:.global)
                            .onChanged { value in
                                dockOffset=CGSize(
                                    width:min(0,max(-max(0,proxy.size.width-136),dockDragStart.width+value.translation.width)),
                                    height:min(0,max(-max(0,proxy.size.height-112),dockDragStart.height+value.translation.height)))
                            }
                            .onEnded { _ in dockDragStart=dockOffset })
                        .padding(.trailing,12).padding(.bottom,max(20,proxy.safeAreaInsets.bottom+8))
                }
            }
            .onAppear { available=proxy.size;remote.resize(proxy.size) }
            .onChange(of:proxy.size) { _,size in
                available=size;dockOffset = .zero;dockDragStart = .zero
                if !text.focused { remote.resize(size) }
            }
        }
        .ignoresSafeArea(.container,edges:.bottom)
        .background { edgeBackground.ignoresSafeArea() }
        .preferredColorScheme(remote.edgeColor.prefersLightContent ? .dark : .light)
        .animation(.easeInOut(duration:0.25),value:remote.edgeColor)
        .onChange(of:interaction.geometry.contentRect) { _,_ in remote.sampleVisibleEdge(interaction.geometry) }
        .overlay(alignment:.top) {
            if let error=remote.error {
                HStack { Text(error).font(.footnote);Button("重试") { remote.retryCurrentLayout() } }
                    .padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).padding(8)
            }
        }
        .overlay(alignment:.topLeading) {
            Color.clear.frame(width:1,height:1).accessibilityElement().accessibilityLabel("WPS 连接状态")
                .accessibilityValue(metadata).accessibilityIdentifier("wpsState").allowsHitTesting(false)
        }
        .onAppear {
            interaction.onEvent={ remote.consume($0,interaction:interaction) }
            remote.onEdit={ value in text.beginEditing(value) }
            remote.onCommitted={ text.cancel() }
        }
        .onChange(of:text.focused) { _,focused in if !focused { remote.resize(available) } }
        .onChange(of:phase) { _,value in if value != .active { text.cancel();interaction.invalidate() } }
        .onDisappear { remote.stop() }
    }
    private var edgeBackground:Color { Color(.sRGB,red:remote.edgeColor.red,green:remote.edgeColor.green,blue:remote.edgeColor.blue,opacity:1) }
    private var floatingTools:some View {
        HStack(spacing:0) {
            Button(action:beginEditing) { Image(systemName:"keyboard").frame(width:52,height:48) }
                .disabled(!remote.ready).accessibilityLabel("编辑选中单元格").accessibilityIdentifier("wpsEdit")
            Divider().frame(height:22)
            Menu {
                Text("当前单元格 \(remote.state?.cell ?? "—")")
                Button("自动铺满",systemImage:"arrow.up.left.and.arrow.down.right") {
                    interaction.setFillsViewport(true)
                }.accessibilityIdentifier("wpsFill")
                Button("显示完整窗口",systemImage:"macwindow") { interaction.setFillsViewport(false) }
                    .accessibilityIdentifier("wpsFit")
                Button(interaction.inspect ? "恢复单元格操作" : "平移查看边缘",systemImage:"hand.draw") { interaction.toggleInspection() }
                Button(interaction.relative ? "直接触摸" : "触控板模式",systemImage:"hand.point.up.left") { interaction.toggleMode() }
                Button("重新适配桌面窗口",systemImage:"arrow.triangle.2.circlepath") { remote.retryResize(available) }
            } label: { Image(systemName:"ellipsis").frame(width:52,height:48) }
            .accessibilityLabel("窗口工具").accessibilityIdentifier("wpsTools")
        }
        .font(.system(size:20,weight:.medium)).buttonStyle(.plain)
        .background(.regularMaterial,in:Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.65),lineWidth:1).allowsHitTesting(false) }
        .shadow(color:.black.opacity(0.14),radius:12,y:3)
    }
    private var editor:some View {
        HStack(spacing:8) {
            Button { text.cancel() } label: { Image(systemName:"xmark").frame(width:36,height:44) }
                .accessibilityLabel("取消编辑").accessibilityIdentifier("wpsCancel")
            Text(remote.state?.cell ?? "").font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
            MobileTextEditor(session:text,onSubmit:submit).frame(height:44)
                .accessibilityIdentifier("wpsCellEditor")
            Button(action:submit) {
                if remote.pendingCommit { ProgressView() }
                else { Image(systemName:"checkmark").fontWeight(.semibold).frame(width:36,height:44) }
            }.disabled(text.composing || remote.pendingCommit).accessibilityLabel("完成编辑").accessibilityIdentifier("wpsDone")
        }
        .font(.system(size:20)).buttonStyle(.plain).padding(6)
        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:20))
        .shadow(color:.black.opacity(0.1),radius:8,y:2)
    }
    private func beginEditing() { guard remote.ready,let state=remote.state else { return };interaction.invalidate();text.beginEditing(state.value) }
    private func submit() { guard !text.composing,!remote.pendingCommit else { return };remote.commit(text.draft) }
    private var focusRect:CGRect? {
        guard text.focused,let point=remote.lastTouch else { return nil }
        return CGRect(x:point.x-15,y:point.y-15,width:140,height:36)
    }
    private var metadata:String {
        let geometry=interaction.geometry
        var value:[String:Any] = ["ready":remote.ready,"pending":remote.pendingCommit,"operations":remote.completedOperations,
            "edgeColorReady":remote.hasEdgeColor,"edgeRed":remote.edgeColor.red,"edgeGreen":remote.edgeColor.green,"edgeBlue":remote.edgeColor.blue,
            "fillsViewport":interaction.fillsViewport,"scale":geometry.scale,"contentX":geometry.contentRect.minX,
            "contentY":geometry.contentRect.minY,"contentWidth":geometry.contentSize.width,"contentHeight":geometry.contentSize.height]
        if let s=remote.state { value.merge(["version":s.version,"width":s.window.width,"height":s.window.height,"cell":s.cell,"value":s.value,"formulaY":s.formula.y,"formulaHeight":s.formula.height,"videoWidth":s.videoWidth,"videoHeight":s.videoHeight],uniquingKeysWith:{$1}) }
        return (try? JSONSerialization.data(withJSONObject:value)).flatMap { String(data:$0,encoding:.utf8) } ?? "{}"
    }
}
#endif
