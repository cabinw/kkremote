#if os(iOS) && canImport(WebRTC)
  import SwiftUI

  @available(iOS 27.1, *)
  struct DuoHingeObserver: UIViewRepresentable {
    let detected: (UIHinge.Status?) -> Void
    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      view.addInteraction(
        UIHingeInteraction { _, update in
          let status = update.hinge?.status
          Task { @MainActor in detected(status) }
        })
      return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
  }

  private struct DockIcon: View, Equatable {
    let data: Data?
    let name: String

    var body: some View {
      if let data, let image = UIImage(data: data) {
        Image(uiImage: image.withRenderingMode(.alwaysOriginal)).resizable().renderingMode(
          .original
        ).scaledToFit()
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: 8).fill(.quaternary)
          Text(String(name.prefix(1))).font(.headline)
        }
      }
    }
  }

  private struct DuoDockPicker: View {
    @ObservedObject var model: LabModel
    let select: (RemoteWindow) -> Void
    @Binding var expandedApp: String?

    var body: some View {
      let groups = Dictionary(
        grouping: model.remoteWindows.filter { $0.displayID == nil }, by: \.dockKey)
      let apps = groups.values.compactMap(\.first).sorted {
        ($0.application, $0.dockKey) < ($1.application, $1.dockKey)
      }
      VStack(alignment: .leading, spacing: 8) {
        if let key = expandedApp, let windows = groups[key], let first = windows.first {
          Button {
            expandedApp = nil
          } label: {
            Label(first.application, systemImage: "chevron.backward")
          }
          ScrollView {
            VStack(alignment: .leading) {
              ForEach(windows) { window in
                Button {
                  select(window)
                } label: {
                  Text(window.title.isEmpty ? window.application : window.title)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(
                      Rectangle())
                }
                .disabled(model.catalogLoading || model.windowBusy)
                .accessibilityIdentifier("remoteWindowRow-\(window.number)")
              }
            }
          }
        } else if apps.isEmpty {
          if model.catalogLoading {
            ProgressView()
          } else {
            Text(model.windowError ?? "没有可共享的应用窗口")
            Button("刷新", systemImage: "arrow.clockwise") { model.refreshRemoteWindows() }
          }
        } else {
          ScrollView {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 48, maximum: 58), spacing: 6)], spacing: 6
            ) {
              ForEach(apps, id: \.dockKey) { app in
                Button {
                  if groups[app.dockKey]?.count == 1 {
                    select(app)
                  } else {
                    expandedApp = app.dockKey
                  }
                } label: {
                  DockIcon(data: model.remoteAppIcons[app.dockKey], name: app.application)
                    .equatable().frame(width: 40, height: 40)
                    .frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
                }
                .accessibilityLabel(app.application)
                .accessibilityIdentifier("duoDockApp-\(app.processID)")
                .disabled(model.catalogLoading || model.windowBusy)
              }
            }
          }
        }
      }
      .padding(12).frame(idealWidth: 240, idealHeight: 170)
      .buttonStyle(.plain)
    }
  }

  struct DuoWorkspace<Video: View, Tools: View>: View {
    @ObservedObject var model: LabModel
    @ObservedObject var viewport: MobileInteractionSession
    @ObservedObject var keyboard: MobileTextSession
    @Binding var showingDock: Bool
    let partiallyOpen: Bool
    let settings: () -> Void
    @ViewBuilder var video: () -> Video
    @ViewBuilder var tools: () -> Tools
    @State private var modifiers = Set<String>()
    @State private var cursor: CGPoint?
    @State private var shortcutHint: String?
    @State private var choosingDesktop = false
    @State private var foldTrackpad = false
    @State private var expandedApp: String?
    @State private var recentApps: [String] = []
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private let tile = Color(white: 0.14)
    private var desktop: RemoteWindow? { model.remoteWindows.first { $0.displayID != nil } }
    private var canType: Bool {
      model.canControl && model.directKeyboardSupported
        && model.selectedRemoteWindow?.displayID == nil
    }
    var body: some View {
      GeometryReader { geometry in
        if let division = horizontalFold(in: geometry) {
          foldedContent(division, size: geometry.size, insets: geometry.safeAreaInsets)
            .statusBarHidden()
        } else {
          touchWorkspace
        }
      }
      .preferredColorScheme(.dark)
      .background(Color.black.ignoresSafeArea())
      .background {
        RemoteKeyboardCapture(session: keyboard, onText: sendText, onKey: sendKey)
          .frame(width: 1, height: 1).clipped()
      }
      .onChange(of: model.selectedRemoteWindow?.id, initial: true) { _, _ in
        if let selected = model.selectedRemoteWindow, selected.displayID == nil,
          let app = model.remoteWindows.first(where: {
            $0.processID == selected.processID && $0.number == selected.number
          })
        {
          recentApps = [app.dockKey] + recentApps.filter { $0 != app.dockKey }.prefix(1)
        }
        cursor = nil
        modifiers.removeAll()
        keyboard.cancel()
      }
      .onChange(of: model.windowBusy) { _, busy in
        if busy {
          keyboard.cancel()
          cursor = nil
          modifiers.removeAll()
        }
      }
      .onChange(of: partiallyOpen) { _, _ in
        foldTrackpad = false
        keyboard.cancel()
        modifiers.removeAll()
      }
      .onDisappear {
        keyboard.cancel()
      }
      .confirmationDialog("共享 Mac 主显示器", isPresented: $choosingDesktop) {
        Button("显示完整桌面") { if let desktop { model.selectRemoteWindow(desktop) } }
      } message: {
        Text("主显示器上的窗口和通知都会出现在 Duo 上。")
      }
    }

    private var touchWorkspace: some View {
      NavigationStack {
        touchContent
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .bottomBar) { dockButton }
            if #available(iOS 27.1, *) {
              ForEach(recentApps.prefix(verticalSizeClass == .compact ? 1 : 2), id: \.self) { key in
                ToolbarItem(placement: .bottomBar) { recentButton(key) }
                  .axisBehavior(.verticalPreferred)
              }
            }
            ToolbarItemGroup(placement: .bottomBar) {
              desktopButton
              Button(
                "键盘", systemImage: keyboard.focused ? "keyboard.chevron.compact.down" : "keyboard"
              ) {
                if keyboard.focused {
                  keyboard.cancel()
                } else {
                  focusIfNeeded()
                  keyboard.focused = true
                }
              }.disabled(!canType).accessibilityIdentifier("phoneKeyboard")
              sessionButtons
            }
          }
      }
    }

    private var desktopButton: some View {
      Button("桌面", systemImage: "desktopcomputer") { choosingDesktop = true }
        .disabled(desktop == nil || model.windowBusy || model.catalogLoading)
        .accessibilityIdentifier("duoDesktop")
    }

    @ViewBuilder private var sessionButtons: some View {
      Menu("会话", systemImage: "ellipsis") { tools() }
        .accessibilityIdentifier("phoneMenu")
      Button("设置", systemImage: "gearshape", action: settings)
        .accessibilityIdentifier("duoSettings")
    }

    private func horizontalFold(in geometry: GeometryProxy) -> CGRect? {
      let bounds = CGRect(origin: .zero, size: geometry.size)
      if #available(iOS 27.1, *), partiallyOpen {
        for region in geometry.reservedRegions(kind: .division) where region.isActive {
          let frame = region.frame
          if frame.width > frame.height, frame.minY > 0, frame.maxY < bounds.height {
            return frame
          }
        }
      }
      return nil
    }

    private func foldedContent(_ fold: CGRect, size: CGSize, insets: EdgeInsets) -> some View {
      VStack(spacing: 0) {
        video().overlay { if foldTrackpad { pointerOverlay } }
          .frame(width: size.width + insets.leading + insets.trailing, height: fold.minY + insets.top)
          .clipped()
          // Extend only the video to the glass. Keep the lower controls in their safe area.
          .padding(EdgeInsets(top: -insets.top, leading: -insets.leading, bottom: 0, trailing: -insets.trailing))
        Color.black.frame(height: fold.height).accessibilityHidden(true)
        VStack(spacing: 4) {
          HStack(spacing: 2) {
            Button(
              foldTrackpad ? "键盘" : "触控板",
              systemImage: foldTrackpad ? "keyboard" : "rectangle.and.hand.point.up.left"
            ) {
              foldTrackpad.toggle()
            }.accessibilityIdentifier("duoFoldInputMode")
            dockButton
            ForEach(recentApps, id: \.self) { recentButton($0, inFold: true) }
            desktopButton
            Spacer(minLength: 0)
            sessionButtons
          }
          .labelStyle(.iconOnly).buttonStyle(FoldMenuButtonStyle())
          .controlSize(.large)
          .foregroundStyle(.white)
          .frame(height: min(44, (size.height - fold.maxY) * 0.17))
          .accessibilityElement(children: .contain).accessibilityIdentifier("duoFoldMenu")
          if foldTrackpad {
            pad
          } else {
            DuoMacKeyboard { key, flags in
              focusIfNeeded()
              model.sendInput(kind: "key", key: key, modifiers: flags)
            }
            .id(model.selectedRemoteWindow?.id)
            .disabled(!model.canControl || !model.physicalKeyboardSupported)
          }
        }
        .padding(6)
        .frame(height: size.height - fold.maxY)
        .background(Color(white: 0.15))
      }
      .onAppear {
        viewport.setFoldPanelWidth(true)
        keyboard.cancel()
        foldTrackpad = false
      }
      .onDisappear { viewport.setFoldPanelWidth(false) }
    }

    @ViewBuilder private func recentButton(_ key: String, inFold: Bool = false) -> some View {
      let windows = model.remoteWindows.filter {
        $0.displayID == nil && $0.dockKey == key
      }
      if let app = windows.first {
        Button {
          if windows.count == 1 {
            model.selectRemoteWindow(app)
          } else {
            expandedApp = key
            showingDock = true
          }
        } label: {
          DockIcon(data: model.remoteAppIcons[key], name: app.application)
            .equatable().frame(width: 26, height: 26)
            .frame(width: inFold ? 44 : 26, height: inFold ? 44 : 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.application)
        .accessibilityIdentifier("duoRecentApp-\(app.processID)")
        .disabled(model.catalogLoading || model.windowBusy)
      }
    }

    private var dockButton: some View {
      Button("Dock", systemImage: "square.grid.2x2") {
        expandedApp = nil
        showingDock = true
      }
      .accessibilityIdentifier("duoDock")
      .disabled(!model.windowSupported || model.windowBusy)
      .popover(isPresented: $showingDock) {
        DuoDockPicker(
          model: model,
          select: { window in
            showingDock = false
            model.selectRemoteWindow(window)
          }, expandedApp: $expandedApp
        )
        .onAppear { model.refreshRemoteWindows() }
        .presentationCompactAdaptation(.popover)
      }
    }

    private var touchContent: some View {
      GeometryReader { proxy in
        let sideBySide = proxy.size.width > proxy.size.height * 1.55 && !keyboard.focused
        let layout =
          sideBySide ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        layout {
          video().overlay { pointerOverlay }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
          VStack(spacing: 7) {
            keys
            if let shortcutHint { Text(shortcutHint).font(.caption).foregroundStyle(.secondary) }
            if !keyboard.focused { pad }
          }
          .frame(
            width: sideBySide ? proxy.size.width * 0.40 : nil,
            height: sideBySide ? nil : (keyboard.focused ? 48 : max(115, proxy.size.height * 0.47)))
        }
        .padding(6)
      }
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
      let next = CGPoint(
        x: min(max(0, p.x + delta.x / g.scale), g.source.width - 0.01),
        y: min(max(0, p.y + delta.y / g.scale), g.source.height - 0.01))
      cursor = next
      if viewport.fitsFoldPanelWidth {
        viewport.reveal(CGRect(origin: next, size: CGSize(width: 1, height: 1)))
      }
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

  }

  private struct FoldMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .font(.system(size: 20, weight: .medium))
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.55 : 1)
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
