#if os(iOS) && targetEnvironment(simulator)
import SwiftUI
import WebRTC

@MainActor final class WPSRemoteSession: ObservableObject {
    @Published private(set) var state:WPSState?
    @Published private(set) var track:RTCVideoTrack?
    @Published private(set) var edgeColor=WindowEdgeColor.initial
    @Published private(set) var hasEdgeColor=false
    private var colorSampler:WPSWindowColorSampler?
    private var sampleRegion=CGRect(x:0.08,y:0.002,width:0.84,height:0.005)
    @Published private(set) var ready=false
    @Published var error:String?
    @Published private(set) var pendingCommit=false
    @Published private(set) var completedOperations=0
    private let config:WPSReviewConfig?
    private var signal:SignalTransport?,engine:PeerEngine?
    private var mediaEpoch=UUID()
    private var tail:Task<Void,Never>?,resizeTask:Task<Void,Never>?
    private var sequence=Int(Date().timeIntervalSince1970*1000),geometryEpoch=0
    private var requested=CGSize.zero
    private var lastTap:(CGPoint,Date)?
    private var scrollDelta=CGSize.zero
    private var scrollTask:Task<Void,Never>?
    var onEdit:((String)->Void)?
    var onCommitted:(()->Void)?
    @Published private(set) var lastTouch:CGPoint?
    init() {
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        config=(try? Data(contentsOf:documents.appendingPathComponent("WPSInteractiveReview.json")))
            .flatMap { try? JSONDecoder().decode(WPSReviewConfig.self,from:$0) }
        if config==nil { error="独立 WPS 测试 Host 未启动" }
    }
    var source:CGSize { state.map { CGSize(width:$0.window.width,height:$0.window.height) } ?? CGSize(width:402,height:730) }
    func sampleVisibleEdge(_ geometry:ViewportGeometry) {
        guard geometry.isValid,let state else { return }
        let visibleX=max(0,-geometry.contentRect.minX/geometry.scale)
        let visibleY=max(0,-geometry.contentRect.minY/geometry.scale)
        let width=min(source.width-visibleX,geometry.viewport.width/geometry.scale)
        let captureScale=min(Double(state.videoWidth)/source.width,Double(state.videoHeight)/source.height)
        // Ignore rounded corners; sample just inside the visible top edge, above title text.
        sampleRegion=CGRect(x:(visibleX+width*0.08)*captureScale/Double(state.videoWidth),
            y:(visibleY+1)*captureScale/Double(state.videoHeight),
            width:width*0.84*captureScale/Double(state.videoWidth),
            height:4*captureScale/Double(state.videoHeight))
        colorSampler?.update(region:sampleRegion)
    }
    func resize(_ viewport:CGSize) {
        guard viewport.width>=200,viewport.height>=150 else { return }
        resizeTask?.cancel()
        resizeTask=Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(300))
            guard !Task.isCancelled,let self,abs(viewport.width-requested.width)>1 || abs(viewport.height-requested.height)>1 else { return }
            requested=viewport;geometryEpoch += 1;ready=false
            stopMedia()
            let epoch=geometryEpoch
            enqueue(WPSRequest(kind:"resize",width:viewport.width,height:viewport.height),epoch:epoch) { [weak self] state in
                self?.connectMedia(state)
            }
        }
    }
    func retryResize(_ viewport:CGSize) { requested = .zero; resize(viewport) }
    func retryCurrentLayout() { let size=requested;requested = .zero;resize(size) }
    func consume(_ event:MobileInputEvent,interaction:MobileInteractionSession) {
        guard ready,!pendingCommit else { return }
        switch event {
        case .buttonUp:
            guard !interaction.isDragging,let point=interaction.pointer,let state else { return }
            lastTouch=point
            let doubleTap=lastTap.map { Date().timeIntervalSince($0.1)<0.5 && hypot(point.x-$0.0.x,point.y-$0.0.y)<24 } ?? false
            lastTap=(point,Date())
            enqueue(WPSRequest(kind:"tap",version:state.version,x:point.x,y:point.y),epoch:geometryEpoch) { [weak self] result in
                if doubleTap { self?.onEdit?(result.value) }
            }
        case let .scroll(delta):
            scrollDelta.width += delta.width;scrollDelta.height += delta.height
            if scrollTask==nil {
                scrollTask=Task { [weak self] in
                    try? await Task.sleep(for:.milliseconds(70))
                    guard !Task.isCancelled,let self else { return };flushScroll();scrollTask=nil
                }
            }
        case .scrollEnd:scrollTask?.cancel();scrollTask=nil;flushScroll()
        default:break
        }
    }
    private func flushScroll() {
        let delta=scrollDelta;scrollDelta = .zero
        guard ready,let state,abs(delta.width)+abs(delta.height)>1 else { return }
        enqueue(WPSRequest(kind:"scroll",version:state.version,dx:delta.width,dy:delta.height),epoch:geometryEpoch)
    }
    func commit(_ text:String) {
        guard ready,!pendingCommit,let state else { return }
        pendingCommit=true
        enqueue(WPSRequest(kind:"commit",version:state.version,cell:state.cell,text:text,id:UUID().uuidString),epoch:geometryEpoch) { [weak self] _ in
            self?.pendingCommit=false;self?.onCommitted?()
        }
    }
    func refresh() {
        guard ready,!pendingCommit,let state else { return }
        enqueue(WPSRequest(kind:"status",version:state.version),epoch:geometryEpoch)
    }
    private func enqueue(_ original:WPSRequest,epoch:Int,completion:((WPSState)->Void)?=nil) {
        let previous=tail
        tail=Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled,let self,epoch==geometryEpoch else { return }
            do {
                guard let config,let url=URL(string:config.url),url.host=="127.0.0.1",url.scheme=="http",url.port==48274 else {
                    throw WPSFailureClient(message:"独立 WPS 测试配置无效")
                }
                sequence=max(sequence+1,Int(Date().timeIntervalSince1970*1000))
                var command=original;command.session=config.session;command.sequence=sequence
                var request=URLRequest(url:url);request.httpMethod="POST";request.timeoutInterval=15
                request.setValue("Bearer \(config.token)",forHTTPHeaderField:"Authorization")
                request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                request.httpBody=try JSONEncoder().encode(command)
                let (data,response)=try await URLSession.shared.data(for:request)
                let result=try JSONDecoder().decode(WPSState.self,from:data)
                guard epoch==geometryEpoch else { return }
                guard (response as? HTTPURLResponse)?.statusCode==200,result.error==nil else {
                    throw WPSFailureClient(message:result.error ?? "WPS 操作失败")
                }
                guard result.session==config.session else { throw WPSFailureClient(message:"WPS 会话已改变") }
                state=result;error=nil;completedOperations += 1;completion?(result)
            } catch {
                guard epoch==geometryEpoch else { return }
                self.error=error.localizedDescription;pendingCommit=false
            }
        }
    }
    private func connectMedia(_ state:WPSState) {
        guard let config else { return }
        do {
            let epoch=UUID();mediaEpoch=epoch
            let e=try PeerEngine(isHost:false,preset:LabPreset(width:state.videoWidth,height:state.videoHeight,fps:30,megabits:8,pattern:.grid),route:.directICE)
            let s=SignalTransport();engine=e;signal=s
            s.onMessage={ [weak e] in e?.receive($0) }
            e.onSignal={ [weak s] in s?.send($0) }
            e.onTrack={ [weak self] value in
                guard let self,mediaEpoch==epoch else { return }
                if let colorSampler { track?.remove(colorSampler);colorSampler.stop() }
                track=value
                let sampler=WPSWindowColorSampler { [weak self] color in
                    Task { @MainActor in
                        guard let self,self.mediaEpoch==epoch else { return }
                        self.edgeColor=color;self.hasEdgeColor=true
                    }
                }
                sampler.update(region:sampleRegion);colorSampler=sampler;value.add(sampler)
            }
            e.onSample={ [weak self] sample in
                guard let self,mediaEpoch==epoch else { return }
                ready=sample.framesDecoded>0 && sample.width==state.videoWidth && sample.height==state.videoHeight
            }
            e.onFailure={ [weak self] value in guard let self,mediaEpoch==epoch else { return };ready=false;error=value }
            s.onFailure={ [weak self] value in guard let self,mediaEpoch==epoch else { return };ready=false;error=value }
            try s.connect(host:"127.0.0.1",key:config.pairingKey,port:config.videoPort)
        } catch { self.error=error.localizedDescription }
    }
    private func stopMedia() { mediaEpoch=UUID();if let colorSampler { track?.remove(colorSampler);colorSampler.stop() };colorSampler=nil;signal?.stop();signal=nil;engine?.stop();engine=nil;track=nil }
    func stop() { resizeTask?.cancel();scrollTask?.cancel();tail?.cancel();stopMedia();ready=false }
}
struct WPSFailureClient:LocalizedError { let message:String;var errorDescription:String? { message } }
#endif
