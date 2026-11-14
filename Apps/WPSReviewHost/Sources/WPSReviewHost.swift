import Foundation
import AppKit
import ScreenCaptureKit

@MainActor final class WPSReviewHost {
    private let ax:WPSAccessibility
    private let directory:URL
    private let config:WPSReviewConfig
    private var server:WPSControlServer?
    private var signal:SignalTransport?
    private var engine:PeerEngine?
    private var version=0,sequence=0
    private var busy=false
    private var state:WPSState
    private var receipts:[String:(String,String)]=[:]
    init(window:SCWindow,directory:URL) throws {
        self.directory=directory
        ax=WPSAccessibility(windowID:window.windowID,pid:window.owningApplication!.processID,title:window.title!)
        config=WPSReviewConfig(url:"http://127.0.0.1:48274/control",token:UUID().uuidString,session:UUID().uuidString,
            pairingKey:try SignalTransport.newPairingKey(),videoPort:48273)
        let snapshot=try ax.inspect(),encoded=WPSWindowLayout.encoded(snapshot.0.size)
        state=WPSState(session:config.session,version:0,window:WPSRect(snapshot.0),videoWidth:Int(encoded.width),videoHeight:Int(encoded.height),
            cell:snapshot.1,value:snapshot.2,formula:WPSRect(snapshot.3),constrained:false)
    }
    func start() throws {
        server=try WPSControlServer(port:48274,token:config.token) { [weak self] bytes in
            guard let self else { return (503,Data()) }
            do {
                let request=try JSONDecoder().decode(WPSRequest.self,from:bytes)
                return (200,try JSONEncoder().encode(await self.handle(request)))
            } catch {
                var failure=self.state;failure.error=error.localizedDescription
                return (409,(try? JSONEncoder().encode(failure)) ?? Data())
            }
        }
        let url=directory.appendingPathComponent("interactive-config.json")
        try JSONEncoder().encode(config).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        persist()
        print("WPS_INTERACTIVE_READY window=\(ax.windowID) videoPort=48273 controlPort=48274");fflush(stdout)
    }
    private func snapshot() throws -> WPSState {
        let value=try ax.inspect()
        guard abs(value.0.width-state.window.width)<1,abs(value.0.height-state.window.height)<1 else {
            throw WPSFailure("桌面窗口尺寸已变化，请重新适配后操作")
        }
        state.window=WPSRect(value.0);state.cell=value.1;state.value=value.2;state.formula=WPSRect(value.3);state.error=nil
        persist();return state
    }
    private func handle(_ request:WPSRequest) async throws -> WPSState {
        guard request.session==config.session else { throw WPSFailure("测试会话已失效") }
        if request.kind=="status" { return try snapshot() }
        guard !busy else { throw WPSFailure("窗口正在调整，请稍后操作") }
        guard request.sequence>sequence else { throw WPSFailure("拒绝过期的输入事件") }
        sequence=request.sequence
        if request.kind=="resize" {
            guard let width=request.width,let height=request.height,width.isFinite,height.isFinite,
                  (200...2000).contains(width),(150...2400).contains(height) else { throw WPSFailure("无效的工作区尺寸") }
            busy=true;defer { busy=false }
            try await stopVideo()
            let frame=try await ax.resize(viewport:CGSize(width:width,height:height))
            version += 1
            let encoded=WPSWindowLayout.encoded(frame.size)
            state.window=WPSRect(frame);state.version=version
            state.videoWidth=Int(encoded.width);state.videoHeight=Int(encoded.height)
            state.constrained=abs(frame.width/frame.height-width/height)>0.015
            try startVideo()
            return try snapshot()
        }
        guard request.version==version,version>0 else { throw WPSFailure("画面尺寸已更新，请等待新画面后再操作") }
        _=try snapshot()
        busy=true;defer { busy=false }
        switch request.kind {
        case "tap":
            guard let x=request.x,let y=request.y,x.isFinite,y.isFinite else { throw WPSFailure("无效触摸坐标") }
            try await ax.click(CGPoint(x:x,y:y))
        case "scroll": try await ax.scroll(dx:request.dx ?? 0,dy:request.dy ?? 0)
        case "commit":
            guard let id=request.id,UUID(uuidString:id) != nil,let text=request.text,let cell=request.cell else { throw WPSFailure("缺少单元格提交信息") }
            if let previous=receipts[id] {
                guard previous.0==cell,previous.1==text else { throw WPSFailure("重复提交编号与内容不一致") }
            } else {
                try await ax.replaceCell(cell,text:text)
                receipts[id]=(cell,text)
                if receipts.count>256 { receipts.removeValue(forKey:receipts.keys.first!) }
            }
        default:throw WPSFailure("不支持的测试操作")
        }
        return try snapshot()
    }
    private func startVideo() throws {
        let preset=LabPreset(width:state.videoWidth,height:state.videoHeight,fps:30,megabits:8,pattern:.grid)
        let e=try PeerEngine(isHost:true,preset:preset,route:.directICE,captureWindowID:ax.windowID,expectedWindowProcessID:ax.pid)
        let s=SignalTransport()
        engine=e;signal=s
        e.onSignal={ [weak s] in s?.send($0) }
        s.onMessage={ [weak e] in e?.receive($0) }
        s.onReady={ [weak e] in e?.startOffer() }
        e.onSample={ [weak self] sample in
            guard let self,let data=try? JSONEncoder().encode(sample) else { return }
            try? data.write(to:self.directory.appendingPathComponent("video-sample.json"),options:.atomic)
        }
        e.onFailure={ value in print("WPS_VIDEO_ERROR \(value)");fflush(stdout) }
        try s.listen(key:config.pairingKey,port:config.videoPort)
    }
    private func stopVideo() async throws {
        signal?.stop();signal=nil
        if let engine {
            self.engine=nil
            await withCheckedContinuation { continuation in engine.stop { continuation.resume() } }
        }
        // Let the old listener release before binding the same isolated port.
        try await Task.sleep(for:.milliseconds(120))
    }
    private func persist() {
        if let data=try? JSONEncoder().encode(state) { try? data.write(to:directory.appendingPathComponent("state.json"),options:.atomic) }
    }
}
