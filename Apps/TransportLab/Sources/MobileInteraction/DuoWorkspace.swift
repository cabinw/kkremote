#if os(iOS) && canImport(WebRTC)
  import SwiftUI
  import CoreImage
  import WebRTC

  @available(iOS 27.1, *)
  struct DuoHingeObserver: UIViewRepresentable {
    let detected: () -> Void
    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      view.addInteraction(
        UIHingeInteraction { _, update in
          if update.hinge != nil { Task { @MainActor in detected() } }
        })
      return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
  }

  /// Cards are populated from windows the user actually viewed, one small image per selection.
  private final class DuoFramePreview: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var taken = false
    private let complete: (UIImage) -> Void
    init(complete: @escaping (UIImage) -> Void) { self.complete = complete }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
      guard let native = frame?.buffer as? RTCCVPixelBuffer else { return }
      lock.lock()
      let capture = !taken
      taken = true
      lock.unlock()
      guard capture else { return }
      let buffer = native.pixelBuffer
      DispatchQueue.global(qos: .utility).async { [complete] in
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(160 / image.extent.width, 90 / image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cg = CIContext().createCGImage(small, from: small.extent) {
          DispatchQueue.main.async { complete(UIImage(cgImage: cg)) }
        }
      }
    }
  }

  private struct DuoWindowIdentity: Hashable {
    let processID: Int32
    let number: UInt32
    init(_ window: RemoteWindow) {
      processID = window.processID
      number = window.number
    }
  }

  struct DuoWorkspace<Video: View, Tools: View>: View {
    @ObservedObject var model: LabModel
    @ObservedObject var viewport: MobileInteractionSession
    @ObservedObject var keyboard: MobileTextSession
    let choose: () -> Void
    let settings: () -> Void
    @ViewBuilder var video: () -> Video
    @ViewBuilder var tools: () -> Tools
    @State private var modifiers = Set<String>()
    @State private var recent: [DuoWindowIdentity] = []
    @State private var pictures: [DuoWindowIdentity: UIImage] = [:]
    @State private var previewTrack: RTCVideoTrack?
    @State private var preview: DuoFramePreview?
    @State private var cursor: CGPoint?
    @State private var shortcutHint: String?
    @State private var choosingDesktop = false
    private let tile = Color(white: 0.14)
    private var desktop: RemoteWindow? { model.remoteWindows.first { $0.displayID != nil } }
    private var canType: Bool {
      model.canControl && model.directKeyboardSupported
        && model.selectedRemoteWindow?.displayID == nil
    }
    private var windows: [RemoteWindow] {
      let list = model.remoteWindows.filter { $0.displayID == nil }
      return recent.compactMap { id in list.first { DuoWindowIdentity($0) == id } }
    }

    var body: some View {
      GeometryReader { proxy in
        let sideBySide = proxy.size.width > proxy.size.height * 1.55 && !keyboard.focused
        let layout =
          sideBySide ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        layout {
          video().overlay { pointerOverlay }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
          VStack(spacing: 7) {
            toolbar
            keys
            if let shortcutHint { Text(shortcutHint).font(.caption).foregroundStyle(.secondary) }
            if !keyboard.focused { pad }
          }
          .frame(
            width: sideBySide ? proxy.size.width * 0.40 : nil,
            height: sideBySide ? nil : (keyboard.focused ? 95 : max(115, proxy.size.height * 0.47)))
        }
        .padding(6)
      }
      .background(Color.black.ignoresSafeArea())
      .preferredColorScheme(.dark)
      .background {
        RemoteKeyboardCapture(session: keyboard, onText: sendText, onKey: sendKey)
          .frame(width: 1, height: 1).clipped()
      }
      .onChange(of: model.selectedRemoteWindow?.id, initial: true) { _, _ in
        cursor = nil
        modifiers.removeAll()
        keyboard.cancel()
        if let window = model.selectedRemoteWindow, window.displayID == nil {
          recent.removeAll { $0 == DuoWindowIdentity(window) }
          recent.insert(DuoWindowIdentity(window), at: 0)
          recent = Array(recent.prefix(12))
          pictures = pictures.filter { recent.contains($0.key) }
        }
        bindPreview()
      }
      .onChange(of: model.track.map(ObjectIdentifier.init)) { _, _ in bindPreview() }
      .onChange(of: model.windowBusy) { _, busy in
        if busy {
          keyboard.cancel()
          cursor = nil
          modifiers.removeAll()
        }
      }
      .onDisappear {
        unbindPreview()
        keyboard.cancel()
      }
      .confirmationDialog("共享 Mac 主显示器", isPresented: $choosingDesktop) {
        Button("显示完整桌面") { if let desktop { model.selectRemoteWindow(desktop) } }
      } message: {
        Text("主显示器上的窗口和通知都会出现在 Duo 上。")
      }
    }

    private var toolbar: some View {
      HStack(spacing: 5) {
        button("窗口", "rectangle.stack", action: choose)
          .accessibilityIdentifier("phoneChooseWindow")
          .disabled(!model.windowSupported || model.windowBusy)
        ScrollView(.horizontal) {
          HStack(spacing: 5) {
            ForEach(windows) { window in
              Button {
                model.selectRemoteWindow(window)
              } label: {
                ZStack(alignment: .bottomLeading) {
                  if let image = pictures[DuoWindowIdentity(window)] {
                    Image(uiImage: image).resizable().scaledToFill()
                  }
                  Text(window.title.isEmpty ? window.application : window.title)
                    .font(.caption2).lineLimit(1).padding(3)
                    .background(.black.opacity(0.70))
                }
                .frame(width: 83, height: 44).clipped()
                .background(tile, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                  RoundedRectangle(cornerRadius: 8).stroke(
                    model.selectedRemoteWindow?.number == window.number
                      && model.selectedRemoteWindow?.displayID == nil ? Color.accentColor : .clear,
                    lineWidth: 2))
              }.accessibilityLabel(window.label).disabled(model.catalogLoading || model.windowBusy)
            }
          }
        }.scrollIndicators(.hidden).frame(maxWidth: .infinity)
        Menu {
          tools()
        } label: {
          tileLabel("会话", "ellipsis")
        }
        .accessibilityIdentifier("phoneMenu")
        button("桌面", "desktopcomputer") { choosingDesktop = true }
          .disabled(desktop == nil || model.windowBusy || model.catalogLoading)
          .accessibilityIdentifier("duoDesktop")
        button("设置", "gearshape", action: settings)
      }
      .buttonStyle(.plain).foregroundStyle(.white)
    }

    private func tileLabel(_ text: String, _ icon: String) -> some View {
      VStack(spacing: 2) {
        Image(systemName: icon)
        Text(text).font(.caption2)
      }
      .frame(minWidth: 39, minHeight: 44).background(tile, in: RoundedRectangle(cornerRadius: 9))
    }
    private func button(_ text: String, _ icon: String, action: @escaping () -> Void) -> some View {
      Button(action: action) { tileLabel(text, icon) }
    }
    private var keys: some View {
      HStack(spacing: 4) {
        ScrollView(.horizontal) {
          HStack(spacing: 4) {
            ForEach(["esc", "tab", "ctrl", "opt", "cmd", "shift", "←", "↓", "↑", "→"], id: \.self) {
              label in
              let modifier = ["ctrl", "opt", "cmd", "shift"].contains(label)
              Button {
                if modifier {
                  shortcutHint = nil
                  if !modifiers.insert(label).inserted { modifiers.remove(label) }
                } else {
                  sendKey(
                    ["esc": "escape", "←": "left", "↓": "down", "↑": "up", "→": "right"][label]
                      ?? label)
                }
              } label: {
                Text(label).font(.callout).frame(minWidth: 42, minHeight: 40)
                  .background(
                    modifiers.contains(label) ? Color.accentColor : tile,
                    in: RoundedRectangle(cornerRadius: 8))
              }.disabled(!canType || (modifier && !model.windowShortcutsSupported))
            }
          }
        }.scrollIndicators(.hidden)
        Button {
          if keyboard.focused {
            keyboard.cancel()
          } else {
            focusIfNeeded()
            keyboard.focused = true
          }
        } label: {
          Image(systemName: keyboard.focused ? "keyboard.chevron.compact.down" : "keyboard")
            .frame(minWidth: 44, minHeight: 40).background(
              tile, in: RoundedRectangle(cornerRadius: 8))
        }.disabled(!canType).accessibilityLabel("键盘").accessibilityIdentifier("phoneKeyboard")
      }.buttonStyle(.plain).foregroundStyle(.white)
    }

    private var pad: some View {
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.068))
        Canvas { ctx, size in
          var dots = Path()
          for y in stride(from: 10, to: size.height, by: 18) {
            for x in stride(from: 10, to: size.width, by: 18) {
              dots.addEllipse(in: CGRect(x: x, y: y, width: 1.4, height: 1.4))
            }
          }
          ctx.fill(dots, with: .color(.white.opacity(0.10)))
        }.accessibilityHidden(true)
        Text(
          model.canControl
            ? "滑动移动指针 · 轻点点击 · 双指滚动" : (model.selectedRemoteWindow == nil ? "选择窗口或桌面" : "仅观看")
        )
        .font(.caption).foregroundStyle(.secondary).padding(8)
        DuoPadGestures(move: move, click: click, scroll: scroll, endScroll: model.flushInputScroll)
          .id(model.selectedRemoteWindow?.id)
          .allowsHitTesting(model.canControl)
      }
    }
    @ViewBuilder private var pointerOverlay: some View {
      if let cursor, model.canControl {
        let p = viewport.geometry.displayPoint(for: cursor)
        Image(systemName: "cursorarrow").foregroundStyle(.white).shadow(color: .black, radius: 2)
          .position(x: p.x + 5, y: p.y + 7).allowsHitTesting(false)
      }
    }
    private func pointer() -> CGPoint {
      cursor
        ?? CGPoint(x: viewport.geometry.source.width / 2, y: viewport.geometry.source.height / 2)
    }
    private func move(_ delta: CGPoint) {
      let g = viewport.geometry
      guard model.canControl, g.isValid else { return }
      let p = pointer()
      cursor = CGPoint(
        x: min(max(0, p.x + delta.x / g.scale), g.source.width - 0.01),
        y: min(max(0, p.y + delta.y / g.scale), g.source.height - 0.01))
    }
    private func click(_ secondary: Bool) {
      guard model.canControl, viewport.geometry.isValid else { return }
      let p = pointer()
      cursor = p
      model.sendInput(kind: secondary ? "secondary" : "click", x: p.x, y: p.y)
    }
    private func scroll(_ delta: CGPoint) {
      let g = viewport.geometry
      guard g.isValid else { return }
      model.queueInputScroll(
        point: pointer(), delta: CGSize(width: delta.x / g.scale, height: delta.y / g.scale))
    }
    private func focusIfNeeded() {
      if model.controlState?.focus == nil { model.sendInput(kind: "focus") }
    }
    private func sendKey(_ key: String) {
      guard canType else { return }
      focusIfNeeded()
      model.sendInput(
        kind: "key", key: key, modifiers: modifiers.isEmpty ? nil : modifiers.sorted())
      modifiers.removeAll()
    }
    private func sendText(_ text: String) {
      shortcutHint = nil
      if modifiers.isEmpty {
        model.sendInput(kind: "insertText", text: text)
        return
      }
      if WindowInput.shortcutCodes[text.lowercased()] != nil {
        sendKey(text.lowercased())
      } else {
        shortcutHint = "此组合键暂不支持"
        modifiers.removeAll()
      }
    }

    private func unbindPreview() {
      if let preview, let previewTrack { previewTrack.remove(preview) }
      preview = nil
      previewTrack = nil
    }
    private func bindPreview() {
      unbindPreview()
      guard let track = model.track, let window = model.selectedRemoteWindow,
        window.displayID == nil
      else { return }
      let renderer = DuoFramePreview { [weak track] image in
        guard let track, model.track === track, model.selectedRemoteWindow?.id == window.id else {
          return
        }
        pictures[DuoWindowIdentity(window)] = image
      }
      previewTrack = track
      preview = renderer
      track.add(renderer)
    }
  }

  private struct DuoPadGestures: UIViewRepresentable {
    let move: (CGPoint) -> Void
    let click: (Bool) -> Void
    let scroll: (CGPoint) -> Void
    let endScroll: () -> Void
    func makeCoordinator() -> Handler { Handler(self) }
    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      view.isAccessibilityElement = true
      view.accessibilityLabel = "触控板"
      view.accessibilityIdentifier = "duoTrackpad"
      let handler = context.coordinator
      let pan = UIPanGestureRecognizer(target: handler, action: #selector(Handler.pan(_:)))
      pan.maximumNumberOfTouches = 2
      view.addGestureRecognizer(pan)
      let tap = UITapGestureRecognizer(target: handler, action: #selector(Handler.tap(_:)))
      let right = UITapGestureRecognizer(target: handler, action: #selector(Handler.tap(_:)))
      right.numberOfTouchesRequired = 2
      for r in [tap, right] {
        r.require(toFail: pan)
        view.addGestureRecognizer(r)
      }
      tap.require(toFail: right)
      return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.actions = self }
    final class Handler: NSObject {
      var actions: DuoPadGestures
      var scrolling = false
      init(_ actions: DuoPadGestures) { self.actions = actions }
      @objc func tap(_ g: UITapGestureRecognizer) { actions.click(g.numberOfTouchesRequired == 2) }
      @objc func pan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { scrolling = false }
        if g.numberOfTouches == 2 { scrolling = true }
        if g.state == .began || g.state == .changed {
          let d = g.translation(in: g.view)
          g.setTranslation(.zero, in: g.view)
          if scrolling { actions.scroll(d) } else { actions.move(d) }
        } else if scrolling {
          actions.endScroll()
          scrolling = false
        }
      }
    }
  }
#endif
