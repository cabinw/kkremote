import Foundation

/// Host-only diagnostic extension; it does not change the media/signalling wire format.
struct CaptureSample: Codable {
    var completeFrames = 0
    var idleFrames = 0
    var otherFrames = 0
    var invalidFrames = 0
    var width = 0
    var height = 0
    var pixelFormat: [String: String]?
    var luma10BitSamples: [String: Int]?
    var sourceWidthPoints: Double = 0
    var sourceHeightPoints: Double = 0
    var pointPixelScale: Double = 0
    var callbackGapMillisecondsP95: Double?
    var callbackGapMillisecondsMax: Double?
    var windowServerAgeMillisecondsP95: Double?
    var windowServerAgeMillisecondsMax: Double?
}

protocol LabVideoSource: AnyObject {
    func start()
    func stop()
    func captureSnapshot() -> CaptureSample?
}

extension LabVideoSource {
    func captureSnapshot() -> CaptureSample? { nil }
}
