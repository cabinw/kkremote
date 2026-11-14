import Foundation
@main enum WindowTitleIdentityTests {
    static func main() {
        func match(_ ax:String,_ title:String,_ app:String="Google Chrome")->Bool {
            WindowTitleIdentity.matches(ax,captureTitle:title,application:app)
        }
        precondition(match("Document","Document","Microsoft Excel"))
        precondition(match("Document - Google Chrome","Document"))
        precondition(!match("Other Document - Google Chrome","Document"))
        precondition(!match("Document - Google Chrome", "Document", "Other App"))
        precondition(!match("Document - Google Chrome - Other","Document"))
        precondition(!match(" - Google Chrome",""))
        let long=String(repeating:"文",count:150)
        precondition(match(long+" - Google Chrome",String(long.prefix(128))))
        print("Window title identity: 7 checks passed")
    }
}
