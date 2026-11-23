import Foundation
import CoreGraphics

// Metadata only. No AppKit activation, SCStream, screenshots or repeated app launches.
let args = CommandLine.arguments
guard args.count == 3, let id = UInt32(args[1]), let seconds = Double(args[2]), seconds > 0 else { exit(2) }
let start = ProcessInfo.processInfo.systemUptime
repeat {
    let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String:Any]] ?? []
    let row = rows.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
    let bounds = row?[kCGWindowBounds as String] as? [String:Any] ?? [:]
    let rect = CGRect(x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                      y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                      width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                      height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
    var displayCount: UInt32 = 0
    let displayStatus = CGGetDisplaysWithRect(rect, UInt32(displayIDs.count), &displayIDs, &displayCount)
    let displays: [[String:Any]] = displayIDs.prefix(Int(displayCount)).sorted().compactMap { displayID in
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return ["id":displayID, "modePoints":[mode.width,mode.height],
                "modePixels":[mode.pixelWidth,mode.pixelHeight], "nominalRefreshHz":mode.refreshRate]
    }
    let result: [String:Any] = ["found":row != nil, "title":row?[kCGWindowName as String] as? String ?? "",
        "application":row?[kCGWindowOwnerName as String] as? String ?? "",
        "dimensionsPoints":[rect.width,rect.height], "displays":displays,
        "displayObservationComplete":displayStatus == .success && displayCount > 0 && displayCount < 32 && displays.count == Int(displayCount)]
    if let data = try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys) {
        FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))
    }
    Thread.sleep(forTimeInterval:min(10,max(0,seconds-(ProcessInfo.processInfo.systemUptime-start))))
} while ProcessInfo.processInfo.systemUptime-start < seconds
