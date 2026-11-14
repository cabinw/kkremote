#if os(iOS)
import SwiftUI

/// Wraps the existing video renderer without replacing its identity on zoom,
/// rotation or tool changes. Source size is used for local display only.
struct MobileViewport<Content: View>: View {
    @ObservedObject var session: MobileInteractionSession
    let source: CGSize
    let target: String
    let focusRect: CGRect?
    let content: (ViewportGeometry) -> Content
    let encodedPixels: CGSize?
    @Environment(\.displayScale) private var displayScale
    let rendersAtDisplaySize: Bool
    let background: Color
    init(session: MobileInteractionSession, source: CGSize, target: String, focusRect: CGRect? = nil, background: Color = .black, encodedPixels: CGSize? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.session = session; self.source = source; self.target = target; self.focusRect = focusRect; self.content = { _ in content() }; self.background = background;self.rendersAtDisplaySize=false;self.encodedPixels=encodedPixels
    }
    init(session: MobileInteractionSession, source: CGSize, target: String, background: Color = .black, encodedPixels: CGSize? = nil, @ViewBuilder displayContent: @escaping (CGSize) -> Content) {
        self.session=session;self.source=source;self.target=target;self.focusRect=nil;self.background=background
        self.content={ displayContent($0.contentSize) };self.rendersAtDisplaySize=true;self.encodedPixels=encodedPixels
    }
    init(session: MobileInteractionSession, source: CGSize, target: String, background: Color = .black, encodedPixels: CGSize?, @ViewBuilder geometryContent: @escaping (ViewportGeometry) -> Content) {
        self.session=session;self.source=source;self.target=target;self.focusRect=nil;self.background=background
        self.content=geometryContent;self.rendersAtDisplaySize=true;self.encodedPixels=encodedPixels
    }
    var body: some View {
        GeometryReader { proxy in
            let geometry = session.makeGeometry(source: source, viewport: proxy.size, encodedPixels: encodedPixels, displayScale: displayScale)
            ZStack(alignment: .topLeading) {
                background
                content(geometry)
                    .frame(width:max(1,rendersAtDisplaySize ? geometry.contentSize.width:source.width),
                           height:max(1,rendersAtDisplaySize ? geometry.contentSize.height:source.height))
                    .scaleEffect(rendersAtDisplaySize ? 1:geometry.scale, anchor: .topLeading)
                    .offset(x: geometry.contentRect.minX, y: geometry.contentRect.minY)
                    .allowsHitTesting(false)
                if session.localInputPreview, session.relative, let pointer = session.pointer {
                    Image(systemName: session.relative ? "cursorarrow" : "scope")
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(.blue)
                        .position(geometry.displayPoint(for: pointer)).allowsHitTesting(false)
                }
                MobileTouchSurface(session: session).frame(width: proxy.size.width, height: proxy.size.height)
            }.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading).clipped()
                .onAppear { session.configure(source: source, viewport: proxy.size, target: target, encodedPixels: encodedPixels, displayScale: displayScale); revealFocus() }
                .onChange(of: proxy.size) { _, size in session.configure(source: source, viewport: size, target: target, encodedPixels: encodedPixels, displayScale: displayScale); revealFocus() }
                .onChange(of: focusRect) { _, _ in revealFocus() }
                .onChange(of: source) { _, size in session.configure(source: size, viewport: proxy.size, target: target, encodedPixels: encodedPixels, displayScale: displayScale) }
                .onChange(of: target) { _, value in session.configure(source: source, viewport: proxy.size, target: value, encodedPixels: encodedPixels, displayScale: displayScale) }
                .onChange(of: encodedPixels) { _, _ in session.configure(source: source, viewport: proxy.size, target: target, encodedPixels: encodedPixels, displayScale: displayScale) }
                .onChange(of: displayScale) { _, _ in session.configure(source: source, viewport: proxy.size, target: target, encodedPixels: encodedPixels, displayScale: displayScale) }
        }.onDisappear { session.invalidate() }
    }
    private func revealFocus() { if let focusRect { session.reveal(focusRect) } }
}
#endif
