#!/usr/bin/env swift
// Records one window to a movie with ScreenCaptureKit: the window alone, wherever it sits —
// behind other windows or on Rocuronium's virtual display — at its backing scale, with no
// cursor. Nothing dims: ScreenCaptureKit shows only its menu-bar indicator, where
// `screencapture -v` darkens every display for the length of the recording.
//
// Usage:
//   swift Scripts/record-window.swift (--window <CGWindowID> | --pid <pid> [--title <text>])
//       --seconds <n> --out <file.mov> [--fps 60] [--scale <pixels per point>] [--bitrate <Mbps>]
//
//   --window   the window's id (`rocuronium windows`, or the Debug showcase's
//              "showcase window: id N" line)
//   --pid      the owning process; `--title` narrows to the first window whose title contains it
//   --scale    defaults to the display's own backing scale
//
// Writes H.264 in a QuickTime movie at the given rate and prints the wall-clock instant of the
// first frame ("first frame: <unix seconds>"), so a recording can be cut to a known moment:
//   ffmpeg -ss <offset> -i out.mov -t <seconds> -c:v libx264 -crf 17 -pix_fmt yuv420p \
//       -movflags +faststart clip.mp4
//
// Needs the Screen Recording grant for the process that runs it (the terminal).

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct Options {
    var windowID: CGWindowID?
    var pid: pid_t?
    var title: String?
    var seconds: Double = 0
    var output = ""
    var fps = 60
    var scale: Double?
    var bitrateMbps = 80.0

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var iterator = arguments.dropFirst().makeIterator()
        while let flag = iterator.next() {
            guard let value = iterator.next() else { return nil }
            switch flag {
            case "--window": options.windowID = CGWindowID(value)
            case "--pid": options.pid = pid_t(value)
            case "--title": options.title = value
            case "--seconds": options.seconds = Double(value) ?? 0
            case "--out": options.output = value
            case "--fps": options.fps = Int(value) ?? 60
            case "--scale": options.scale = Double(value)
            case "--bitrate": options.bitrateMbps = Double(value) ?? 80
            default: return nil
            }
        }
        guard options.windowID != nil || options.pid != nil, options.seconds > 0, !options.output.isEmpty else { return nil }
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("record-window: \(message)\n".utf8))
    exit(1)
}

/// Appends each complete frame to the movie; frames ScreenCaptureKit marks idle carry no image
/// and are skipped (the previous frame simply holds).
final class Writer: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var started = false
    private(set) var frames = 0

    init(url: URL, width: Int, height: Int, bitrate: Double, fps: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate * 1_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }

    func stream(_: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, isComplete(buffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        if !started {
            guard writer.startWriting() else { fail("cannot start writing: \(String(describing: writer.error))") }
            let pts = buffer.presentationTimeStamp
            writer.startSession(atSourceTime: pts)
            started = true
            // The sample's host-clock time, as wall-clock seconds.
            let lag = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CMTimeGetSeconds(pts)
            print(String(format: "first frame: %.4f", Date().timeIntervalSince1970 - lag))
            fflush(stdout)
        }
        if input.isReadyForMoreMediaData, input.append(buffer) { frames += 1 }
    }

    private func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    func finish() async {
        lock.lock()
        let wasStarted = started
        lock.unlock()
        guard wasStarted else { fail("no frame arrived — is the window on screen, and is Screen Recording granted?") }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { fail("writing failed: \(String(describing: writer.error))") }
    }
}

guard let options = Options.parse(CommandLine.arguments) else {
    fail("usage: record-window.swift (--window <id> | --pid <pid> [--title <text>]) --seconds <n> --out <file.mov> [--fps 60] [--scale <n>] [--bitrate <Mbps>]")
}

// A window-server connection first: ScreenCaptureKit asserts on one, and a script has none
// until AppKit opens it.
_ = NSApplication.shared

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
let window = content.windows.first { window in
    if let id = options.windowID { return window.windowID == id }
    guard window.owningApplication?.processID == options.pid else { return false }
    guard let title = options.title else { return window.frame.width > 1 && window.frame.height > 1 }
    return (window.title ?? "").localizedCaseInsensitiveContains(title)
}
guard let window else { fail("no such window") }

let filter = SCContentFilter(desktopIndependentWindow: window)
let scale = options.scale ?? Double(filter.pointPixelScale)
let width = Int((window.frame.width * scale).rounded())
let height = Int((window.frame.height * scale).rounded())

let configuration = SCStreamConfiguration()
configuration.width = width
configuration.height = height
configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
configuration.showsCursor = false
configuration.pixelFormat = kCVPixelFormatType_32BGRA
configuration.colorSpaceName = CGColorSpace.sRGB
configuration.queueDepth = 8
configuration.capturesAudio = false

let url = URL(fileURLWithPath: (options.output as NSString).expandingTildeInPath)
try? FileManager.default.removeItem(at: url)
let writer = try Writer(url: url, width: width, height: height, bitrate: options.bitrateMbps, fps: options.fps)
let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: DispatchQueue(label: "record-window.frames"))

print("recording window \(window.windowID) '\(window.title ?? "")' at \(width)×\(height), \(options.fps) fps, \(options.seconds) s")
/// Starts or stops the stream and waits for ScreenCaptureKit to confirm it.
func run(_ call: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        call { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
}

try await run { stream.startCapture(completionHandler: $0) }
try await Task.sleep(for: .seconds(options.seconds))
try await run { stream.stopCapture(completionHandler: $0) }
await writer.finish()
print("wrote \(writer.frames) frames to \(url.path)")
