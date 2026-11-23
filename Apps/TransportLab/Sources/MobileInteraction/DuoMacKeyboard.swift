#if os(iOS)
import SwiftUI

/// Compact ANSI layout for the lower panel of a horizontally folded Duo.
struct DuoMacKeyboard: View {
    let send: (String, [String]) -> Void
    @State private var modifiers = Set<String>()
    @State private var caps = false
    @State private var fn = false

    private struct Key {
        let code: String
        let title: String
        let shifted: String?
        let width: CGFloat

        init(_ code: String, _ title: String? = nil, _ width: CGFloat = 1, shifted: String? = nil) {
            self.code = code
            self.title = title ?? code
            self.shifted = shifted
            self.width = width
        }
    }

    private static func symbols(_ plain: String, _ shifted: String) -> [Key] {
        zip(plain, shifted).map { Key(String($0), shifted: String($1)) }
    }

    private static func letters(_ row: String) -> [Key] {
        row.map { Key(String($0), String($0).uppercased()) }
    }

    private static let rows: [[Key]] = [
        [Key("escape", "esc", 1.3)] + (1...12).map { Key("F\($0)") },
        symbols("`1234567890-=", "~!@#$%^&*()_+") + [Key("backspace", "delete", 1.55)],
        [Key("tab", "tab", 1.45)] + letters("qwertyuiop") + symbols("[]\\", "{}|"),
        [Key("caps", "caps lock", 1.65)] + letters("asdfghjkl") + symbols(";'", ":\"") + [Key("return", "return", 1.7)],
        [Key("shift", "⇧ shift", 2)] + letters("zxcvbnm") + symbols(",./", "<>?") + [Key("shift", "shift ⇧", 2)],
        [Key("fn"), Key("ctrl", "⌃"), Key("opt", "⌥"), Key("cmd", "⌘", 1.25), Key(" ", "", 5),
         Key("cmd", "⌘", 1.25), Key("opt", "⌥"), Key("left", "←"), Key("vertical"), Key("right", "→")]
    ]

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = geometry.size.width > 500 ? 4 : 3
            let height = max(1, (geometry.size.height - gap * 5) / 5.75)
            VStack(spacing: gap) {
                ForEach(Self.rows.indices, id: \.self) { index in
                    let row = Self.rows[index]
                    let unit = max(1, (geometry.size.width - gap * CGFloat(row.count - 1)) / row.reduce(0) { $0 + $1.width })
                    HStack(spacing: gap) {
                        ForEach(row.indices, id: \.self) { column in
                            let key = row[column]
                            if key.code == "vertical" {
                                VStack(spacing: 2) {
                                    cap(Key("up", "↑"))
                                    cap(Key("down", "↓"))
                                }.frame(width: unit)
                            } else {
                                cap(key).frame(width: unit * key.width)
                            }
                        }
                    }.frame(height: index == 0 ? height * 0.75 : height)
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duoMacKeyboard")
    }

    private func cap(_ key: Key) -> some View {
        let active = modifiers.contains(key.code) || (caps && key.code == "caps") || (fn && key.code == "fn")
        let navigation = fn ? Self.fnKeys[key.code] : nil
        let modifierNames = ["cmd": "command", "opt": "option", "ctrl": "control"]
        return Button {
            switch key.code {
            case "caps": caps.toggle()
            case "fn": fn.toggle()
            case "ctrl", "opt", "cmd", "shift":
                if !modifiers.insert(key.code).inserted { modifiers.remove(key.code) }
            default:
                var flags = modifiers
                if caps { flags.insert("caps") }
                send(navigation?.code ?? key.code, flags.sorted())
                modifiers.removeAll()
                fn = false
            }
        } label: {
            VStack(spacing: 1) {
                if let shifted = key.shifted {
                    Text(shifted).font(.caption2).foregroundStyle(modifiers.contains("shift") ? .white : .secondary)
                }
                Text(navigation?.title ?? key.title)
                    .font(key.code.count == 1 || modifierNames[key.code] != nil ? .body : .caption)
                if let name = modifierNames[key.code] {
                    Text(name).font(.system(size: 9))
                }
            }
            .lineLimit(1).minimumScaleFactor(0.55).padding(.horizontal, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(active ? Color.accentColor : Color(white: 0.075), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.code == " " ? "空格" : modifierNames[key.code] ?? navigation?.title ?? key.title)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("duoKey-\(key.code == " " ? "space" : key.code)")
    }

    private static let fnKeys: [String: (code: String, title: String)] = [
        "left": ("home", "home"), "right": ("end", "end"), "up": ("pageUp", "pg up"),
        "down": ("pageDown", "pg dn"), "backspace": ("deleteForward", "⌦")
    ]
}
#endif
