#if os(iOS)
import SwiftUI
import UIKit

@MainActor
final class MobileTextSession: ObservableObject {
    @Published private(set) var draft = ""
    @Published private(set) var composing = false
    @Published private(set) var revision = 0
    @Published var focused = false
    var onCommit: (String, UUID) -> Void = { _, _ in }
    var onStableChange: (String) -> Void = { _ in }
    func beginEditing(_ value: String) { revision += 1; draft = value; composing = false; focused = true }
    var canCommit: Bool { !composing && !draft.isEmpty }

    func receive(text: String, marked: Bool, revision: Int) {
        guard revision == self.revision else { return }
        let changed = draft != text || composing != marked
        if draft != text { draft = text }
        if composing != marked { composing = marked }
        if changed && focused && !marked { onStableChange(text) }
    }
    func commit() {
        guard canCommit else { return }
        let value = draft
        // Clear before invoking the sink, so reentrant / repeated submits cannot
        // deliver the same draft twice. A later protocol adapter can reuse this ID.
        revision += 1; draft = ""; composing = false
        onCommit(value, UUID())
    }
    func cancel() { revision += 1; draft = ""; composing = false; focused = false }
}

struct MobileTextEditor: UIViewRepresentable {
    @ObservedObject var session: MobileTextSession
    var inlineSearch = false
    var onSubmit: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(session, inlineSearch:inlineSearch, onSubmit:onSubmit) }
    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.text = session.draft
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 10
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.accessibilityIdentifier = "textDraft"
        view.accessibilityLabel = "输入文字"
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        if onSubmit != nil { view.returnKeyType = .done }
        view.escape = { [weak session] in session?.cancel() }
        if inlineSearch {
            view.font = .systemFont(ofSize:17)
            view.backgroundColor = .black; view.textColor = .white
            view.layer.cornerRadius = 0; view.isScrollEnabled = false
            view.textContainer.lineFragmentPadding = 0
            view.textContainerInset = UIEdgeInsets(top:9,left:4,bottom:7,right:4)
            view.returnKeyType = .done
            view.accessibilityIdentifier = "inlineSearchField"
            view.accessibilityLabel = "搜索 X"

        }
        return view
    }
    func updateUIView(_ view: ComposerTextView, context: Context) { context.coordinator.onSubmit = onSubmit; context.coordinator.synchronize(view) }
    static func dismantleUIView(_ view: ComposerTextView, coordinator: Coordinator) {
        coordinator.suppressed = true; view.delegate = nil; view.resignFirstResponder()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let session: MobileTextSession
        var revision: Int
        var suppressed = false
        let inlineSearch: Bool
        var onSubmit: (() -> Void)?
        init(_ session: MobileTextSession, inlineSearch: Bool = false, onSubmit: (() -> Void)? = nil) {
            self.session = session; revision = session.revision; self.inlineSearch = inlineSearch; self.onSubmit = onSubmit
        }
        @objc func finishEditing() { session.cancel() }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", let onSubmit { if textView.markedTextRange == nil { onSubmit() }; return false }
            if inlineSearch && text == "\n" { finishEditing(); return false }
            return true
        }
        func synchronize(_ view: UITextView) {
            suppressed = true
            defer { suppressed = false }
            if revision != session.revision {
                // unmarkText may invoke delegates. Ignore those callbacks and
                // clear the native buffer before accepting the new target epoch.
                view.unmarkText(); view.text = session.draft
                view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
                revision = session.revision
            }
            if session.focused && !view.isFirstResponder { view.becomeFirstResponder() }
            if !session.focused && view.isFirstResponder { view.resignFirstResponder() }
        }
        func textViewDidChange(_ textView: UITextView) { capture(textView) }
        func textViewDidChangeSelection(_ textView: UITextView) { capture(textView) }
        func textViewDidEndEditing(_ textView: UITextView) {
            // System keyboard dismissal must not refocus or later submit an old
            // composition when another UI update happens.
            guard !suppressed, revision == session.revision else { return }
            session.cancel()
        }
        private func capture(_ view: UITextView) {
            guard !suppressed, revision == session.revision else { return }
            session.receive(text: view.text ?? "", marked: view.markedTextRange != nil, revision: revision)
        }
    }
}

final class ComposerTextView: UITextView {
    var escape: () -> Void = {}
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelDraft))]
    }
    @objc private func cancelDraft() { escape() }
}

struct MobileTextComposer: View {
    @ObservedObject var session: MobileTextSession
    var compact = false
    var showHint = true
    var submitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom) {
                MobileTextEditor(session: session).frame(height: compact ? 48 : 78)
                let layout = compact ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
                layout {
                    Button(submitting ? "发送中…":"发送") { session.commit() }.disabled(!session.canCommit || submitting)
                        .accessibilityIdentifier("commitText")
                    Button("取消") { session.cancel() }.accessibilityIdentifier("cancelText")
                }.buttonStyle(.bordered)
            }
            if showHint {
                Text(session.composing ? "选择候选词后再发送" : (compact ? "输入完成后发送" : "支持中文与多行输入，发送前可编辑"))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("compositionStatus")
            }
        }
    }
}

/// A transparent first responder for the system keyboard. It holds only the
/// current IME composition; committed text is immediately forwarded and cleared.
final class RemoteKeyboardTextView:UITextView {
    var onText:(String)->Void = { _ in }
    var onKey:(String)->Void = { _ in }
    var editingDepth=0
    private var clearing=false
    override var hasText:Bool { true } // Backspace must work against remote content.
    func discardComposition() {
        clearing=true;super.unmarkText();text="";selectedRange=NSRange(location:0,length:0);clearing=false
    }
    func forwardConfirmedText() {
        guard !clearing,editingDepth==0,markedTextRange==nil,let value=text,!value.isEmpty else { return }
        clearing=true;text="";selectedRange=NSRange(location:0,length:0);clearing=false
        onText(value)
    }
    override func insertText(_ text:String) {
        if markedTextRange==nil,text=="\n" || text=="\t" {
            forwardConfirmedText();onKey(text=="\n" ? "return":"tab");return
        }
        editingDepth += 1;super.insertText(text);editingDepth -= 1;forwardConfirmedText()
    }
    override func setMarkedText(_ markedText:String?,selectedRange:NSRange) {
        editingDepth += 1;super.setMarkedText(markedText,selectedRange:selectedRange);editingDepth -= 1
    }
    override func unmarkText() {
        editingDepth += 1;super.unmarkText();editingDepth -= 1;forwardConfirmedText()
    }
    override func deleteBackward() {
        if markedTextRange != nil {
            editingDepth += 1;super.deleteBackward();editingDepth -= 1
        } else { forwardConfirmedText();onKey("backspace") }
    }
    override func resignFirstResponder()->Bool { discardComposition();return super.resignFirstResponder() }
    override var keyCommands:[UIKeyCommand]? {
        [(UIKeyCommand.inputEscape,"escape"),("\t","tab"),(UIKeyCommand.inputLeftArrow,"left"),
         (UIKeyCommand.inputRightArrow,"right"),(UIKeyCommand.inputUpArrow,"up"),(UIKeyCommand.inputDownArrow,"down")].map {
            UIKeyCommand(input:$0.0,modifierFlags:[],action:#selector(remoteKey(_:)))
        }
    }
    @objc private func remoteKey(_ command:UIKeyCommand) {
        let keys=[UIKeyCommand.inputEscape:"escape","\t":"tab",UIKeyCommand.inputLeftArrow:"left",
                  UIKeyCommand.inputRightArrow:"right",UIKeyCommand.inputUpArrow:"up",UIKeyCommand.inputDownArrow:"down"]
        guard markedTextRange==nil,let input=command.input,let key=keys[input] else { return }
        forwardConfirmedText();onKey(key)
    }
}

struct RemoteKeyboardCapture:UIViewRepresentable {
    @ObservedObject var session:MobileTextSession
    var onText:(String)->Void
    var onKey:(String)->Void
    func makeCoordinator()->Coordinator { Coordinator(session) }
    func makeUIView(context:Context)->RemoteKeyboardTextView {
        let view=RemoteKeyboardTextView()
        view.backgroundColor = .clear;view.textColor = .clear;view.tintColor = .clear
        view.clipsToBounds=true;view.isScrollEnabled=false
        view.autocorrectionType = .no;view.autocapitalizationType = .none
        view.smartQuotesType = .no;view.smartDashesType = .no;view.smartInsertDeleteType = .no
        view.inputAssistantItem.leadingBarButtonGroups=[];view.inputAssistantItem.trailingBarButtonGroups=[]
        view.accessibilityIdentifier="remoteKeyboardInput";view.accessibilityLabel="远程键盘"
        view.delegate=context.coordinator;return view
    }
    func updateUIView(_ view:RemoteKeyboardTextView,context:Context) {
        view.onText=onText;view.onKey=onKey
        context.coordinator.synchronize(view)
    }
    static func dismantleUIView(_ view:RemoteKeyboardTextView,coordinator:Coordinator) {
        coordinator.suppressed=true;view.onText={ _ in };view.onKey={ _ in }
        view.delegate=nil;view.discardComposition();view.resignFirstResponder()
    }
    final class Coordinator:NSObject,UITextViewDelegate {
        let session:MobileTextSession
        var revision:Int
        var suppressed=false
        init(_ session:MobileTextSession) { self.session=session;revision=session.revision }
        func synchronize(_ view:RemoteKeyboardTextView) {
            suppressed=true;defer { suppressed=false }
            if revision != session.revision { view.discardComposition();revision=session.revision }
            if session.focused && !view.isFirstResponder { view.becomeFirstResponder() }
            if !session.focused && view.isFirstResponder { view.resignFirstResponder() }
        }
        func textViewDidChange(_ textView:UITextView) {
            guard !suppressed,revision==session.revision else { return }
            (textView as? RemoteKeyboardTextView)?.forwardConfirmedText()
        }
        func textViewDidEndEditing(_ textView:UITextView) {
            guard !suppressed else { return };session.cancel()
        }
    }
}
#endif
