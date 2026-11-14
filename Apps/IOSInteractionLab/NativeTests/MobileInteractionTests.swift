import XCTest
import UIKit
import SwiftUI
@testable import KKRemoteInteraction

final class MobileInteractionTests: XCTestCase {
    @MainActor func testRemoteKeyboardForwardsCommittedTextAndSpecialKeysWithoutDraft() {
        let view=RemoteKeyboardTextView()
        var events=[String]()
        view.onText={ events.append("text:"+$0) };view.onKey={ events.append("key:"+$0) }
        view.insertText("abc");view.insertText("中文🙂")
        view.deleteBackward();view.insertText("\n");view.insertText("\t")
        XCTAssertEqual(events,["text:abc","text:中文🙂","key:backspace","key:return","key:tab"])
        XCTAssertEqual(view.text,"")
    }
    @MainActor func testRemoteKeyboardDoesNotSendMarkedPinyinOrCancelledComposition() {
        let view=RemoteKeyboardTextView()
        var events=[String]()
        view.onText={ events.append($0) };view.onKey={ events.append($0) }
        view.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0))
        view.forwardConfirmedText();XCTAssertTrue(events.isEmpty)
        view.setMarkedText("中文",selectedRange:NSRange(location:2,length:0))
        view.unmarkText();view.forwardConfirmedText()
        XCTAssertEqual(events,["中文"]);XCTAssertEqual(view.text,"")
        view.setMarkedText("wen",selectedRange:NSRange(location:3,length:0))
        view.deleteBackward();XCTAssertEqual(events,["中文"])
        view.discardComposition();view.forwardConfirmedText()
        XCTAssertEqual(events,["中文"]);XCTAssertEqual(view.text,"")
    }

    @MainActor func testWholeWindowLockSurvivesGesturesResizeAndTargetSwitch() {
        let session=MobileInteractionSession(fillsViewport:true,locksWholeWindow:true)
        for (source,viewport,target) in [
            (CGSize(width:500,height:1015),CGSize(width:430,height:873),"excel"),
            (CGSize(width:814,height:430),CGSize(width:814,height:430),"excel"),
            (CGSize(width:900,height:1068),CGSize(width:430,height:873),"other")
        ] {
            session.configure(source:source,viewport:viewport,target:target)
            session.handle(.zoom(3,CGPoint(x:100,y:100)))
            session.handle(.pan(CGSize(width:-200,height:100)))
            session.zoomIn();session.setFillsViewport(true)
            session.reveal(CGRect(x:800,y:800,width:100,height:100))
            XCTAssertEqual(session.zoom,1);XCTAssertEqual(session.offset,.zero)
            XCTAssertFalse(session.fillsViewport)
            let r=session.geometry.contentRect
            XCTAssertGreaterThanOrEqual(r.minX,-0.001);XCTAssertGreaterThanOrEqual(r.minY,-0.001)
            XCTAssertLessThanOrEqual(r.maxX,viewport.width+0.001)
            XCTAssertLessThanOrEqual(r.maxY,viewport.height+0.001)
        }
    }
    private func contact(_ id: Int, _ x: CGFloat, _ y: CGFloat) -> InteractionGestureMachine.Contact {
        .init(id: id, point: CGPoint(x: x, y: y))
    }
    func testWindowEdgeColorRejectsIconsAndRequiresStableThemeChange() {
        func pixels(_ rgb:[UInt8],_ count:Int)->[UInt8] { Array(repeating:rgb+[255],count:count).flatMap{$0} }
        var estimator=WindowEdgeColorEstimator()
        let sample=pixels([235,235,235],120)+pixels([15,15,15],30)+pixels([220,40,30],20)+Array(repeating:[0,0,0,0],count:20).flatMap{$0}
        let light=estimator.consume(sample)!
        XCTAssertEqual(light.red,235.0/255,accuracy:0.001)
        XCTAssertFalse(light.prefersLightContent)
        XCTAssertFalse(WindowEdgeColor(red:0.6,green:0.6,blue:0.6).prefersLightContent)
        XCTAssertNil(estimator.consume(pixels([236,236,236],120)))
        XCTAssertNil(estimator.consume(pixels([28,30,34],120)))
        XCTAssertNil(estimator.consume(sample)) // A one-frame dark overlay must not change the status bar.
        XCTAssertNil(estimator.consume(pixels([28,30,34],120)))
        let dark=estimator.consume(pixels([28,30,34],120))!
        XCTAssertTrue(dark.prefersLightContent)
        XCTAssertEqual(dark.blue,34.0/255,accuracy:0.001)
    }
    func testAmbiguousOrTransparentWindowEdgeKeepsLastColor() {
        var estimator=WindowEdgeColorEstimator()
        let initial=estimator.consume(Array(repeating:[UInt8(50),80,130,255],count:100).flatMap{$0})!
        var noisy=[UInt8]()
        for i in 0..<16 {
            let pixel:[UInt8]=[UInt8(i*16),UInt8(255-i*16),UInt8(i*16),255]
            for _ in 0..<4 { noisy.append(contentsOf:pixel) }
        }
        XCTAssertNil(estimator.consume(noisy))
        XCTAssertNil(estimator.consume(Array(repeating:0,count:256)))
        XCTAssertNil(estimator.consume([1,2,3]))
        XCTAssertEqual(estimator.current,initial)
    }
    @MainActor func testFillCoversViewportAndKeepsTouchAlignedThroughPanAndZoom() {
        let session=MobileInteractionSession(localInputPreview:true,fillsViewport:true)
        let source=CGSize(width:672,height:1084),viewport=CGSize(width:402,height:812)
        session.configure(source:source,viewport:viewport,target:"wps")
        XCTAssertEqual(session.geometry.contentRect.minX,0,accuracy:0.001)
        XCTAssertEqual(session.geometry.contentRect.minY,0,accuracy:0.001)
        XCTAssertGreaterThanOrEqual(session.geometry.contentSize.width,viewport.width)
        XCTAssertEqual(session.geometry.contentSize.height,viewport.height,accuracy:0.001)
        let cell=CGPoint(x:212,y:282.5)
        session.handle(.tap(session.geometry.displayPoint(for:cell)))
        XCTAssertEqual(session.pointer!.x,cell.x,accuracy:0.001)
        XCTAssertEqual(session.pointer!.y,cell.y,accuracy:0.001)
        session.toggleInspection();session.handle(.pan(CGSize(width:-60,height:0)))
        session.handle(.zoom(1.3,CGPoint(x:200,y:300)))
        XCTAssertTrue(session.geometry.fillsViewport)
        let g=session.geometry,point=CGPoint(x:200,y:300)
        let mapped=g.sourcePoint(at:point)!
        XCTAssertEqual(g.displayPoint(for:mapped).x,point.x,accuracy:0.001)
        XCTAssertEqual(g.displayPoint(for:mapped).y,point.y,accuracy:0.001)
        session.setFillsViewport(false)
        XCTAssertLessThan(session.geometry.contentSize.height,viewport.height)
        session.setFillsViewport(true)
        session.configure(source:CGSize(width:750,height:280),viewport:CGSize(width:812,height:350),target:"landscape")
        XCTAssertGreaterThanOrEqual(session.geometry.contentSize.width,812)
        XCTAssertGreaterThanOrEqual(session.geometry.contentSize.height,350)
    }
    @MainActor func testCellEditorReturnDoesNotCommitMarkedChinese() {
        let session=MobileTextSession();session.beginEditing("")
        var submissions=0
        let coordinator=MobileTextEditor.Coordinator(session,onSubmit:{submissions += 1})
        let view=ComposerTextView();view.delegate=coordinator
        view.setMarkedText("nihao",selectedRange:NSRange(location:5,length:0))
        coordinator.textViewDidChange(view)
        XCTAssertFalse(coordinator.textView(view,shouldChangeTextIn:NSRange(location:5,length:0),replacementText:"\n"))
        XCTAssertEqual(submissions,0)
        view.insertText("你好");coordinator.textViewDidChange(view)
        XCTAssertFalse(coordinator.textView(view,shouldChangeTextIn:NSRange(location:2,length:0),replacementText:"\n"))
        XCTAssertEqual(submissions,1)
        XCTAssertEqual(session.draft,"你好")
    }
    @MainActor func testInlineInputOnlySynchronizesConfirmedTextAndDeletion() {
        let session = MobileTextSession(); session.beginEditing("")
        let coordinator = MobileTextEditor.Coordinator(session,inlineSearch:true)
        let view = ComposerTextView();view.delegate = coordinator
        var edits:[String] = [];session.onStableChange = { edits.append($0) }
        view.setMarkedText("nihao",selectedRange:NSRange(location:5,length:0))
        coordinator.textViewDidChange(view);XCTAssertTrue(edits.isEmpty)
        view.insertText("你好");coordinator.textViewDidChange(view)
        XCTAssertEqual(edits,["你好"])
        coordinator.textViewDidChangeSelection(view)
        XCTAssertEqual(edits,["你好"])
        view.deleteBackward();coordinator.textViewDidChange(view)
        XCTAssertEqual(edits,["你好","你"])
        view.deleteBackward();coordinator.textViewDidChange(view)
        XCTAssertEqual(edits,["你好","你",""])
    }
    @MainActor func testInlineCancelDiscardsCompositionAndRestoresExistingValue() {
        let session = MobileTextSession(), view = ComposerTextView()
        let coordinator = MobileTextEditor.Coordinator(session,inlineSearch:true);view.delegate = coordinator
        var edits:[String] = [];session.onStableChange = { edits.append($0) }
        session.beginEditing("已有文字");coordinator.synchronize(view)
        XCTAssertEqual(view.text,"已有文字");XCTAssertTrue(edits.isEmpty)
        view.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0))
        coordinator.textViewDidChange(view);XCTAssertTrue(edits.isEmpty)
        coordinator.finishEditing()
        view.unmarkText();coordinator.textViewDidChange(view)
        XCTAssertTrue(edits.isEmpty);XCTAssertFalse(session.focused)
        session.beginEditing("已有文字");coordinator.synchronize(view)
        XCTAssertEqual(view.text,"已有文字");XCTAssertNil(view.markedTextRange)
    }

    func testDirectSwipeScrollEndsWithoutClickOrDrag() {
        var machine = InteractionGestureMachine(); machine.directScroll = true
        _ = machine.update([contact(1, 100, 200)], at: 0)
        XCTAssertEqual(machine.update([contact(1, 100, 170)], at: 0.1),
            [.scrollBegan(CGPoint(x:100,y:200)), .scroll(CGSize(width:0,height:-30))])
        XCTAssertEqual(machine.update([contact(1, 100, 140)], at: 0.6), [.scroll(CGSize(width:0,height:-30))])
        XCTAssertEqual(machine.update([], at: 0.7), [.scrollEnded])
        XCTAssertEqual(machine.update([], at: 0.8), [])
    }
    func testDirectScrollPromotionToPinchReleasesScrollOnce() {
        var machine = InteractionGestureMachine(); machine.directScroll = true
        _ = machine.update([contact(1,100,200)],at:0)
        _ = machine.update([contact(1,100,170)],at:0.1)
        XCTAssertEqual(machine.update([contact(1,100,170),contact(2,200,170)],at:0.2),[.scrollEnded])
        let pinch = machine.update([contact(1,80,170),contact(2,220,170)],at:0.3)
        XCTAssertTrue(pinch.contains { if case .zoom = $0 { return true }; return false })
        XCTAssertFalse(pinch.contains { if case .scroll = $0 { return true }; return false })
        XCTAssertEqual(machine.update([],at:0.4),[])
    }
    func testAdaptiveWindowSizingPreservesUsableAspectAndRejectsInvalidSize() {
        for size in [CGSize(width:402,height:657), CGSize(width:750,height:292), CGSize(width:280,height:500)] {
            let result = MobileWindowSizing.proposal(for:size)!
            XCTAssertEqual(result.width/result.height,size.width/size.height,accuracy:0.005)
            XCTAssertGreaterThanOrEqual(result.width,320)
        }
        XCTAssertNil(MobileWindowSizing.proposal(for:.zero))
        XCTAssertNil(MobileWindowSizing.proposal(for:CGSize(width:CGFloat.infinity,height:600)))
        XCTAssertEqual(MobileWindowSizing.proposal(for:CGSize(width:402,height:657),mode:.desktop),CGSize(width:1280,height:800))
    }
    func testCaptureCanvasPreservesRetinaWindowPixelsWithinBudget() {
        XCTAssertEqual(MobileWindowSizing.capturePixels(for:CGSize(width:500,height:1015),pointPixelScale:2,maximumPixels:2560*1440),CGSize(width:1000,height:2030))
        XCTAssertEqual(MobileWindowSizing.capturePixels(for:CGSize(width:814,height:430),pointPixelScale:2,maximumPixels:2560*1440),CGSize(width:1628,height:860))
        let bounded=MobileWindowSizing.capturePixels(for:CGSize(width:3000,height:2000),pointPixelScale:2,maximumPixels:2560*1440)!
        XCTAssertLessThanOrEqual(bounded.width*bounded.height,2560*1440)
        XCTAssertEqual(bounded.width.truncatingRemainder(dividingBy:2),0)
        XCTAssertEqual(bounded.height.truncatingRemainder(dividingBy:2),0)
        XCTAssertEqual(bounded.width/bounded.height,1.5,accuracy:0.003)
        XCTAssertNil(MobileWindowSizing.capturePixels(for:.zero,pointPixelScale:2,maximumPixels:100))
        XCTAssertNil(MobileWindowSizing.capturePixels(for:CGSize(width:500,height:1000),pointPixelScale:.nan,maximumPixels:100))
    }
    @MainActor func testPhoneKeyboardKeepsFullWidthAndTouchCoordinates() {
        let session=MobileInteractionSession(directScroll:true,locksWholeWindow:true)
        let source=CGSize(width:500,height:1015)
        session.configure(source:source,viewport:CGSize(width:430,height:873),target:"excel")
        let full=session.geometry
        session.setKeyboardPresented(true)
        session.configure(source:source,viewport:CGSize(width:430,height:390),target:"excel")
        let keyboard=session.geometry
        XCTAssertEqual(keyboard.contentRect.width,430,accuracy:0.001)
        XCTAssertEqual(keyboard.scale,full.scale,accuracy:0.001)
        XCTAssertEqual(keyboard.contentRect.minY,0)
        XCTAssertGreaterThan(keyboard.contentRect.height,keyboard.viewport.height)
        XCTAssertEqual(keyboard.sourcePoint(at:CGPoint(x:172,y:258)),CGPoint(x:200,y:300))
        XCTAssertNil(keyboard.sourcePoint(at:CGPoint(x:172,y:400)))
        session.setKeyboardPresented(false)
        session.configure(source:source,viewport:CGSize(width:430,height:873),target:"excel")
        XCTAssertEqual(session.geometry.contentRect,full.contentRect)
        session.setKeyboardPresented(true)
        session.configure(source:CGSize(width:814,height:430),viewport:CGSize(width:814,height:180),target:"landscape")
        XCTAssertEqual(session.geometry.contentRect.width,814)
        XCTAssertEqual(session.geometry.contentRect.minX,0)
    }
    @MainActor func testKeyboardResizePreservesScaleAndRevealsSourceFocus() {
        let session = MobileInteractionSession(localInputPreview:true)
        let source = CGSize(width:402,height:657)
        session.configure(source:source,viewport:source,target:"x")
        session.zoomIn()
        let scale = session.geometry.scale
        session.configure(source:source,viewport:CGSize(width:402,height:300),target:"x")
        XCTAssertEqual(session.geometry.scale,scale,accuracy:0.001)
        let focus = CGRect(x:115,y:10,width:200,height:40)
        session.reveal(focus)
        XCTAssertGreaterThanOrEqual(session.geometry.displayPoint(for:focus.origin).y,0)
        XCTAssertLessThanOrEqual(session.geometry.displayPoint(for:CGPoint(x:focus.maxX,y:focus.maxY)).y,300)
        session.configure(source:source,viewport:source,target:"x")
        XCTAssertEqual(session.geometry.scale,scale,accuracy:0.001)
    }
    @MainActor func testReadOnlyDirectScrollPolicyStillCannotEmitEvents() {
        let session = MobileInteractionSession(directScroll:true)
        var events:[MobileInputEvent] = []; session.onEvent = {events.append($0)}
        session.configure(source:CGSize(width:400,height:600),viewport:CGSize(width:400,height:600),target:"live")
        session.handle(.scrollBegan(CGPoint(x:100,y:100)));session.handle(.scroll(CGSize(width:0,height:40)))
        session.handle(.scrollEnded);session.commit("中文",id:UUID())
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor func testRemoteLeaseEnablesMappedTapAndRevocationEndsScroll() {
        let session=MobileInteractionSession(directScroll:true,locksWholeWindow:true)
        var events:[MobileInputEvent]=[];session.onEvent={ events.append($0) }
        session.configure(source:CGSize(width:500,height:1000),viewport:CGSize(width:250,height:500),target:"test")
        session.handle(.tap(CGPoint(x:50,y:100)))
        XCTAssertTrue(events.isEmpty)
        session.enableRemoteInput(true)
        session.handle(.tap(CGPoint(x:50,y:100)))
        XCTAssertEqual(events,[.move(CGPoint(x:100,y:200)),.buttonDown,.buttonUp])
        events=[]
        session.handle(.scrollBegan(CGPoint(x:50,y:100)))
        session.handle(.scroll(CGSize(width:0,height:-20)))
        session.enableRemoteInput(false)
        XCTAssertEqual(events,[.move(CGPoint(x:100,y:200)),.scroll(CGSize(width:0,height:-40)),.scrollEnd])
        events=[]
        session.handle(.tap(CGPoint(x:50,y:100)));session.commit("中文",id:UUID())
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(session.zoom,1);XCTAssertEqual(session.offset,.zero)
    }

    func testPinchDoesNotEmitScrollAndSuppressesRemainingFinger() {
        var machine = InteractionGestureMachine()
        _ = machine.update([contact(1, 100, 100), contact(2, 200, 100)], at: 0)
        let events = machine.update([contact(1, 80, 100), contact(2, 220, 100)], at: 0.1)
        XCTAssertTrue(events.contains { if case .zoom = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .scroll = $0 { return true }; if case .scrollBegan = $0 { return true }; return false })
        XCTAssertEqual(machine.update([contact(1, 80, 100)], at: 0.2), [])
        XCTAssertEqual(machine.update([], at: 0.3), [])
    }
    func testScrollLocksUntilLiftAndEndsOnlyOnce() {
        var machine = InteractionGestureMachine()
        _ = machine.update([contact(1, 100, 100), contact(2, 200, 100)], at: 0)
        XCTAssertEqual(machine.update([contact(1, 100, 130), contact(2, 200, 130)], at: 0.1),
                       [.scrollBegan(CGPoint(x: 150, y: 100)), .scroll(CGSize(width: 0, height: 30))])
        let spread = machine.update([contact(1, 50, 150), contact(2, 250, 150)], at: 0.2)
        XCTAssertEqual(spread, [.scroll(CGSize(width: 0, height: 20))])
        XCTAssertEqual(machine.update([contact(1, 50, 150)], at: 0.3), [.scrollEnded])
        XCTAssertEqual(machine.update([], at: 0.4), [])
    }
    func testHoldDragAndCancellation() {
        var machine = InteractionGestureMachine()
        _ = machine.update([contact(1, 100, 100)], at: 0)
        XCTAssertEqual(machine.update([contact(1, 140, 100)], at: 0.5),
                       [.dragBegan(CGPoint(x: 100, y: 100)), .dragMoved(CGPoint(x: 140, y: 100))])
        XCTAssertEqual(machine.cancel(), [.cancel])
        XCTAssertEqual(machine.update([contact(1, 160, 100)], at: 0.6), [])
        XCTAssertEqual(machine.update([], at: 0.7), [])
    }
    func testContinuousTrackpadMovementNeverBecomesHoldDrag() {
        var machine = InteractionGestureMachine(); machine.relative = true
        _ = machine.update([contact(1, 100, 100)], at: 0)
        XCTAssertEqual(machine.update([contact(1, 120, 100)], at: 0.1), [.relativeMove(CGSize(width: 20, height: 0))])
        XCTAssertEqual(machine.update([contact(1, 140, 100)], at: 0.6), [.relativeMove(CGSize(width: 20, height: 0))])
        XCTAssertEqual(machine.update([], at: 0.7), [])
    }
    func testInspectionPanDoesNotEmitInputAndThirdTouchCancels() {
        var machine = InteractionGestureMachine(); machine.inspect = true
        _ = machine.update([contact(1, 100, 100)], at: 0)
        XCTAssertEqual(machine.update([contact(1, 120, 100)], at: 0.2), [.pan(CGSize(width: 20, height: 0))])
        XCTAssertEqual(machine.update([contact(1, 120, 100), contact(2, 200, 100), contact(3, 300, 100)], at: 0.3), [.cancel])
        XCTAssertEqual(machine.update([], at: 0.4), [])
    }

    @MainActor func testTargetChangeReleasesDragAndScrollWithoutSendingToNewTarget() {
        let session = MobileInteractionSession(localInputPreview: true)
        var events: [MobileInputEvent] = []; session.onEvent = { events.append($0) }
        session.configure(source: CGSize(width: 1000, height: 1000), viewport: CGSize(width: 500, height: 500), target: "a")
        session.handle(.dragBegan(CGPoint(x: 250, y: 250)))
        XCTAssertTrue(session.isDragging)
        session.configure(source: CGSize(width: 1000, height: 1000), viewport: CGSize(width: 500, height: 500), target: "b")
        session.handle(.dragMoved(CGPoint(x: 300, y: 300)))
        XCTAssertFalse(session.isDragging)
        XCTAssertEqual(events.filter { $0 == .buttonUp }.count, 1)
        session.handle(.scrollBegan(CGPoint(x: 250, y: 250))); session.handle(.scroll(CGSize(width: 0, height: 20)))
        session.invalidate(); session.invalidate()
        XCTAssertEqual(events.filter { $0 == .scrollEnd }.count, 1)
    }
    @MainActor func testTrackpadDragUsesRelativePositionAndClampsAtEdge() {
        let session = MobileInteractionSession(localInputPreview: true)
        session.configure(source: CGSize(width: 1000, height: 1000), viewport: CGSize(width: 500, height: 500), target: "a")
        session.toggleMode()
        session.handle(.dragBegan(CGPoint(x: 20, y: 20)))
        session.handle(.dragMoved(CGPoint(x: 30, y: 20)))
        XCTAssertEqual(session.pointer, CGPoint(x: 520, y: 500))
        session.handle(.dragMoved(CGPoint(x: 3000, y: -3000)))
        XCTAssertLessThan(session.pointer!.x, 1000); XCTAssertEqual(session.pointer!.y, 0)
        session.handle(.dragEnded); XCTAssertFalse(session.isDragging)
    }
    @MainActor func testReadOnlyClientCannotEmitInputButCanZoom() {
        let session = MobileInteractionSession()
        var events: [MobileInputEvent] = []; session.onEvent = { events.append($0) }
        session.configure(source: CGSize(width: 1000, height: 1000), viewport: CGSize(width: 500, height: 500), target: "a")
        session.handle(.tap(CGPoint(x: 250, y: 250)))
        session.handle(.dragBegan(CGPoint(x: 250, y: 250)))
        session.handle(.scrollBegan(CGPoint(x: 250, y: 250))); session.handle(.scroll(CGSize(width: 0, height: 30)))
        session.commit("不应发送", id: UUID())
        session.handle(.zoom(2, CGPoint(x: 250, y: 250)))
        XCTAssertEqual(session.zoom, 2); XCTAssertTrue(events.isEmpty)
    }
    @MainActor func testLetterboxCannotStartClickDragOrScroll() {
        let session = MobileInteractionSession(localInputPreview: true)
        var events: [MobileInputEvent] = []; session.onEvent = { events.append($0) }
        session.configure(source: CGSize(width: 1280, height: 720), viewport: CGSize(width: 400, height: 700), target: "a")
        session.handle(.tap(CGPoint(x: 200, y: 10)))
        session.handle(.dragBegan(CGPoint(x: 200, y: 10)))
        session.handle(.dragMoved(CGPoint(x: 200, y: 350)))
        session.handle(.scrollBegan(CGPoint(x: 200, y: 10)))
        session.handle(.scroll(CGSize(width: 0, height: 30)))
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor func testMarkedChineseIsNotCommittedAndConfirmedTextIsDeliveredOnce() {
        let session = MobileTextSession()
        let coordinator = MobileTextEditor.Coordinator(session)
        let view = ComposerTextView(); view.delegate = coordinator
        var commits: [String] = []; session.onCommit = { text, _ in commits.append(text) }
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        coordinator.textViewDidChange(view)
        XCTAssertNotNil(view.markedTextRange); XCTAssertTrue(session.composing)
        session.commit(); XCTAssertTrue(commits.isEmpty)
        view.insertText("你好")
        coordinator.textViewDidChange(view)
        XCTAssertNil(view.markedTextRange); XCTAssertEqual(session.draft, "你好")
        session.commit(); session.commit()
        XCTAssertEqual(commits, ["你好"])
        coordinator.synchronize(view)
        XCTAssertEqual(view.text, "")
    }
    @MainActor func testCancelledCompositionIgnoresStaleDelegateAndClearsNativeBuffer() {
        let session = MobileTextSession(), view = ComposerTextView()
        let coordinator = MobileTextEditor.Coordinator(session); view.delegate = coordinator
        view.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0))
        coordinator.textViewDidChange(view); XCTAssertTrue(session.composing)
        session.cancel()
        view.insertText("中文"); coordinator.textViewDidChange(view)
        XCTAssertEqual(session.draft, ""); XCTAssertFalse(session.composing)
        coordinator.synchronize(view)
        XCTAssertNil(view.markedTextRange); XCTAssertEqual(view.text, "")
    }
    @MainActor func testUnicodeDeletionSelectionReplacementAndMultiline() {
        let session = MobileTextSession(), view = ComposerTextView()
        let coordinator = MobileTextEditor.Coordinator(session); view.delegate = coordinator
        view.insertText("中文👨‍👩‍👧‍👦"); view.deleteBackward(); coordinator.textViewDidChange(view)
        XCTAssertEqual(session.draft, "中文")
        view.selectedRange = NSRange(location: 0, length: 2)
        view.insertText("你好\n世界"); coordinator.textViewDidChange(view)
        XCTAssertEqual(session.draft, "你好\n世界")
        var value = ""; session.onCommit = { text, _ in value = text }
        session.commit(); XCTAssertEqual(value, "你好\n世界")
    }
    @MainActor func testSystemKeyboardDismissalCancelsUnsentText() {
        let session = MobileTextSession(), view = ComposerTextView()
        let coordinator = MobileTextEditor.Coordinator(session); view.delegate = coordinator
        session.focused = true
        view.insertText("未发送"); coordinator.textViewDidChange(view)
        coordinator.textViewDidEndEditing(view)
        XCTAssertEqual(session.draft, ""); XCTAssertFalse(session.focused)
        XCTAssertFalse(session.canCommit)
    }
    @MainActor func testPixelExactSessionMapsTouchesAndRestoresAfterKeyboard() {
        let session=MobileInteractionSession(localInputPreview:true,locksWholeWindow:true)
        let source=CGSize(width:645,height:1309), pixels=CGSize(width:1290,height:2618), viewport=CGSize(width:430,height:873)
        session.configure(source:source,viewport:viewport,target:"pixel-window",encodedPixels:pixels,displayScale:3)
        let exact=session.geometry
        XCTAssertTrue(exact.pixelExact)
        var events=[MobileInputEvent]();session.onEvent={ events.append($0) }
        session.handle(.tap(exact.displayPoint(for:CGPoint(x:321,y:1000))))
        XCTAssertEqual(session.pointer!.x,321,accuracy:0.000001)
        XCTAssertEqual(session.pointer!.y,1000,accuracy:0.000001)
        let count=events.count
        session.handle(.tap(CGPoint(x:200,y:872.9)))
        XCTAssertEqual(events.count,count)
        session.setKeyboardPresented(true)
        session.configure(source:source,viewport:CGSize(width:430,height:518),target:"pixel-window",encodedPixels:pixels,displayScale:3)
        XCTAssertFalse(session.geometry.pixelExact)
        XCTAssertEqual(session.geometry.contentSize.width,430)
        session.setKeyboardPresented(false)
        session.configure(source:source,viewport:viewport,target:"pixel-window",encodedPixels:pixels,displayScale:3)
        XCTAssertEqual(session.geometry.contentRect,exact.contentRect)
        session.configure(source:source,viewport:viewport,target:"pixel-window",encodedPixels:nil,displayScale:3)
        XCTAssertFalse(session.geometry.pixelExact)
        session.configure(source:source,viewport:viewport,target:"pixel-window",encodedPixels:pixels,displayScale:3)
        XCTAssertTrue(session.geometry.pixelExact)
        XCTAssertEqual(session.geometry.contentRect,session.makeGeometry(source:source,viewport:viewport,encodedPixels:pixels,displayScale:3).contentRect)
    }

    @MainActor func testPixelExactViewportAndHitTestingShareGeometryWithoutRemount() {
        let scene=UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let previous=scene.windows.first { $0.isKeyWindow }
        let window=UIWindow(windowScene:scene)
        let session=MobileInteractionSession(locksWholeWindow:true)
        let counter=RendererCounter()
        let source=CGSize(width:645,height:1309),pixels=CGSize(width:1290,height:2618)
        func root(_ encoded:CGSize?) -> some View {
            MobileViewport(session:session,source:source,target:"pixel-window",encodedPixels:encoded,geometryContent: { geometry in
                RendererProbe(counter:counter,geometry:geometry)
            }).frame(width:430,height:873).environment(\.displayScale,3)
        }
        let host=UIHostingController(rootView:root(nil))
        window.rootViewController=host;window.makeKeyAndVisible()
        defer { window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
        func layout() { window.layoutIfNeeded();RunLoop.main.run(until:Date(timeIntervalSinceNow:0.08)) }
        layout();XCTAssertFalse(session.geometry.pixelExact)
        host.rootView=root(pixels);layout()
        XCTAssertTrue(session.geometry.pixelExact)
        XCTAssertEqual(counter.geometry?.contentRect,session.geometry.contentRect)
        XCTAssertEqual(counter.view!.bounds.width*3,1290,accuracy:0.000001)
        XCTAssertEqual(counter.view!.bounds.height*3,2618,accuracy:0.000001)
        host.rootView=root(CGSize(width:1280,height:720));layout()
        XCTAssertFalse(session.geometry.pixelExact)
        XCTAssertEqual(counter.geometry?.contentRect,session.geometry.contentRect)
        host.rootView=root(pixels);layout()
        XCTAssertTrue(session.geometry.pixelExact)
        XCTAssertEqual(counter.created,1);XCTAssertEqual(counter.destroyed,0)
    }

    @MainActor func testViewportKeepsEmbeddedRendererMountedAcrossZoomAndLayout() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let session = MobileInteractionSession()
        let counter = RendererCounter()
        func root(_ width: CGFloat) -> some View {
            MobileViewport(session: session, source: CGSize(width: 1280, height: 720), target: "fixed",displayContent: { _ in
                RendererProbe(counter: counter)
            }).frame(width: width, height: 250)
        }
        let host = UIHostingController(rootView: root(300))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func layout() { window.layoutIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06)) }
        layout(); XCTAssertEqual(counter.created, 1)
        session.zoomIn(); layout()
        session.fit(); layout()
        host.rootView = root(500); layout()
        XCTAssertEqual(counter.created, 1)
        XCTAssertEqual(counter.destroyed, 0)
    }
}

private final class RendererCounter { var created = 0; var destroyed = 0; var geometry:ViewportGeometry?; weak var view:UIView? }
private struct RendererProbe: UIViewRepresentable {
    let counter: RendererCounter
    var geometry:ViewportGeometry? = nil
    func makeCoordinator() -> RendererCounter { counter }
    func makeUIView(context: Context) -> UIView { counter.created += 1;let view=UIView();counter.view=view;return view }
    func updateUIView(_ view: UIView, context: Context) { counter.geometry=geometry }
    static func dismantleUIView(_ view: UIView, coordinator: RendererCounter) { coordinator.destroyed += 1 }
}
