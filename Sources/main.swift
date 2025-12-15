/*
 * This file is part of macosrec.
 *
 * Copyright (C) 2024 Álvaro Ramírez https://xenodium.com
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import AVFoundation
import AppKit
import ArgumentParser
import Cocoa

let packageVersion = "0.9.0"

var recorder: WindowRecorder?

signal(SIGINT) { _ in
  recorder?.save()
}

signal(SIGTERM) { _ in
  recorder?.abort()
  exit(1)
}

struct RecordCommand: ParsableCommand {
  @Flag(name: [.customLong("version")], help: "Show version.")
  var showVersion: Bool = false

  @Flag(name: .shortAndLong, help: "List recordable windows.")
  var list: Bool = false

  @Flag(name: .long, help: "Also include hidden windows when listing.")
  var hidden: Bool = false

  @Option(
    name: [.customShort("x"), .long],
    help: ArgumentHelp(
      "Take a screenshot.", valueName: "app name or window id"))
  var screenshot: String?

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp(
      "Start recording (mov format).", valueName: "app name or window id")
  )
  var record: String?

  @Flag(name: .shortAndLong, help: "Save active recording.")
  var save: Bool = false

  @Flag(name: .shortAndLong, help: "Abort active recording.")
  var abort: Bool = false

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp(valueName: "optional output file path"))
  var output: String?

  mutating func run() throws {
    if showVersion {
      guard let binPath = CommandLine.arguments.first else {
        print("Error: binary name not available")
        Darwin.exit(1)
      }
      print("\(URL(fileURLWithPath: binPath).lastPathComponent) \(packageVersion)")
      Darwin.exit(0)
    }

    if list {
      NSWorkspace.shared.printWindowList(includeHidden: hidden)
      Darwin.exit(0)
    }

    if hidden {
      print("Error: can't use --hidden with anything other than --list")
      Darwin.exit(1)
    }

    if let windowIdentifier = screenshot {
      if record != nil {
        print("Error: can't use --screenshot and --record simultaneously")
        Darwin.exit(1)
      }

      if let output = output,
        URL(fileURLWithPath: output).pathExtension != "png"
      {
        print("Error: --output must be a .png file for screenshots")
        Darwin.exit(1)
      }

      let identifier = resolveWindowID(windowIdentifier)
      if let output = output {
        recorder = WindowRecorder(.png, for: identifier, URL(fileURLWithPath: output))
      } else {
        recorder = WindowRecorder(.png, for: identifier)
      }
      recorder?.save()
      Darwin.exit(0)
    }

    if let windowIdentifier = record {
      if recordingPid() != nil {
        print("Error: Already recording")
        Darwin.exit(1)
      }

      if screenshot != nil {
        print("Error: can't use --screenshot and --record simultaneously")
        Darwin.exit(1)
      }

      if let output = output,
        URL(fileURLWithPath: output).pathExtension != "mov"
      {
        print("Error: --output must be a .mov file for recordings")
        Darwin.exit(1)
      }

      let identifier = resolveWindowID(windowIdentifier)
      if let output = output {
        recorder = WindowRecorder(.mov, for: identifier, URL(fileURLWithPath: output))
      } else {
        recorder = WindowRecorder(.mov, for: identifier)
      }
      recorder?.record()
      return
    }

    if save {
      guard let recordingPid = recordingPid() else {
        print("Error: No recording")
        Darwin.exit(1)
      }
      let result = kill(recordingPid, SIGINT)
      if result != 0 {
        print("Error: Could not stop recording")
        Darwin.exit(1)
      }
      Darwin.exit(0)
    }

    if abort {
      guard let recordingPid = recordingPid() else {
        print("Error: No recording")
        Darwin.exit(1)
      }
      let result = kill(recordingPid, SIGTERM)
      if result != 0 {
        print("Error: Could not abort recording")
        Darwin.exit(1)
      }
      Darwin.exit(0)
    }
  }
}

guard CommandLine.arguments.count > 1 else {
  print("\(RecordCommand.helpMessage())")
  exit(1)
}
RecordCommand.main()
RunLoop.current.run()

struct WindowInfo {
  let app: String
  let title: String
  let identifier: CGWindowID
}

extension NSWorkspace {
  func printWindowList(includeHidden: Bool) {
    for window in allWindows(includeHidden: includeHidden) {
      if window.title.isEmpty {
        print("\(window.identifier) \(window.app)")
      } else {
        print("\(window.identifier) \(window.app) - \(window.title)")
      }
    }
  }

  func window(identifiedAs windowIdentifier: CGWindowID) -> WindowInfo? {
    allWindows(includeHidden: true).first {
      $0.identifier == windowIdentifier
    }
  }

  func allWindows(includeHidden: Bool) -> [WindowInfo] {
    var windowInfos = [WindowInfo]()
    let windows =
      CGWindowListCopyWindowInfo(includeHidden ? .optionAll : .optionOnScreenOnly, kCGNullWindowID)
      as? [[String: Any]]
    for app in NSWorkspace.shared.runningApplications {
      for window in windows ?? [] {
        if let windowPid = window[kCGWindowOwnerPID as String] as? Int,
          windowPid == app.processIdentifier,
          let identifier = window[kCGWindowNumber as String] as? Int,
          let appName = app.localizedName
        {
          let title = window[kCGWindowName as String] as? String ?? ""
          windowInfos.append(
            WindowInfo(app: appName, title: title, identifier: CGWindowID(identifier)))
        }
      }
    }
    return windowInfos
  }
}

class WindowRecorder {
  private let window: WindowInfo
  private let fps: Int32 = 10
  private var timer: Timer?
  private let urlOverride: URL?
  private let mediaType: MediaType
  
  // For streaming MOV files
  private var assetWriter: AVAssetWriter?
  private var assetWriterInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var frameNumber: Int64 = 0
  private var videoWidth: Int = 0
  private var videoHeight: Int = 0
  private let processingQueue = DispatchQueue(label: "com.macosrec.processing", qos: .userInitiated)

  enum MediaType {
    case mov
    case png
  }

  var interval: Double {
    1.0 / Double(fps)
  }

  init(_ mediaType: MediaType, for windowIdentifier: CGWindowID, _ urlOverride: URL? = nil) {
    guard let foundWindow = NSWorkspace.shared.window(identifiedAs: windowIdentifier) else {
      print("Error: window not found")
      exit(1)
    }
    self.urlOverride = urlOverride
    self.window = foundWindow
    self.mediaType = mediaType
  }

  func record() {
    // Get initial window dimensions
    guard let firstImage = windowImage() else {
      print("Error: Could not capture initial window frame")
      exit(1)
    }
    
    guard let resizedImage = firstImage.resize(compressionFactor: 1.0, scale: 0.7) else {
      print("Error: Could not resize initial frame")
      exit(1)
    }
    
    videoWidth = resizedImage.width
    videoHeight = resizedImage.height
    
    // Initialize the MOV writer immediately
    guard let outputURL = urlOverride ?? getDesktopFileURL(suffix: window.app, ext: ".mov") else {
      print("Error: Could not create output URL")
      exit(1)
    }
    
    // Create the file immediately so third-party tools can detect it
    do {
      assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    } catch {
      print("Error: Could not create asset writer: \(error.localizedDescription)")
      exit(1)
    }
    
    let videoSettings: [String: AnyObject] = [
      AVVideoCodecKey: AVVideoCodecType.h264 as AnyObject,
      AVVideoWidthKey: videoWidth as AnyObject,
      AVVideoHeightKey: videoHeight as AnyObject,
    ]
    
    assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    assetWriterInput?.expectsMediaDataInRealTime = true
    
    pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: assetWriterInput!,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
        kCVPixelBufferWidthKey as String: videoWidth,
        kCVPixelBufferHeightKey as String: videoHeight,
      ]
    )
    
    assetWriter?.add(assetWriterInput!)
    
    if assetWriter?.startWriting() != true {
      print("Error: Could not start writing: \(assetWriter?.error?.localizedDescription ?? "Unknown")")
      exit(1)
    }
    
    assetWriter?.startSession(atSourceTime: .zero)
    
    print("Recording to: \((outputURL.path as NSString).abbreviatingWithTildeInPath)")
    
    // Start the timer to capture frames
    timer?.invalidate()
    timer = Timer.scheduledTimer(
      withTimeInterval: TimeInterval(interval), repeats: true,
      block: { [weak self] _ in
        guard let self = self else {
          print("Error: No recorder")
          exit(1)
        }
        self.captureAndWriteFrame()
      })
  }
  
  private func captureAndWriteFrame() {
    guard let image = windowImage() else {
      print("Error: No image from window")
      exit(1)
    }
    
    processingQueue.async { [weak self] in
      guard let self = self else { return }
      
      guard let resizedImage = image.resize(compressionFactor: 1.0, scale: 0.7) else {
        print("Error: Could not resize frame")
        exit(1)
      }
      
      // Check if dimensions match (window might have been resized)
      if resizedImage.width != self.videoWidth || resizedImage.height != self.videoHeight {
        print("Warning: Window dimensions changed, skipping frame")
        return
      }
      
      guard let assetWriterInput = self.assetWriterInput,
            let pixelBufferAdaptor = self.pixelBufferAdaptor else {
        return
      }
      
      // Wait until the writer is ready
      while !assetWriterInput.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.01)
      }
      
      let presentationTime = CMTime(value: self.frameNumber, timescale: self.fps)
      
      if let pixelBuffer = createPixelBufferFromCGImage(
        cgImage: resizedImage, width: self.videoWidth, height: self.videoHeight)
      {
        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        self.frameNumber += 1
      }
    }
  }

  func abort() {
    print("Aborted")
    timer?.invalidate()
    
    if let assetWriter = assetWriter {
      assetWriter.cancelWriting()
    }
  }

  func save() {
    switch mediaType {
    case .mov:
      saveMov()
    case .png:
      savePng()
    }
  }

  private func savePng() {
    do {
      guard let image = windowImage() else {
        print("Error: No window image")
        exit(1)
      }
      guard let url = urlOverride ?? getDesktopFileURL(suffix: window.app, ext: ".png") else {
        print("Error: could not create URL for screenshot")
        exit(1)
      }
      guard let data = image.pngData(compressionFactor: 1) else {
        print("Error: No png data")
        exit(1)
      }
      try data.write(to: url)
      print("\((url.path as NSString).abbreviatingWithTildeInPath)")
      exit(0)
    } catch {
      print("Error: \(error.localizedDescription)")
      exit(1)
    }
  }

  private func windowImage() -> CGImage? {
    return CGWindowListCreateImage(
      CGRect.null, CGWindowListOption.optionIncludingWindow, self.window.identifier,
      CGWindowImageOption.boundsIgnoreFraming)
  }

  private func saveMov() {
    print("Saving...")
    timer?.invalidate()
    
    // Wait for any pending frames to be written
    processingQueue.sync { }
    
    guard let assetWriterInput = assetWriterInput,
          let assetWriter = assetWriter else {
      print("Error: No asset writer")
      exit(1)
    }
    
    assetWriterInput.markAsFinished()
    
    let outputURL = assetWriter.outputURL
    
    assetWriter.finishWriting {
      if assetWriter.status == .completed {
        print("\((outputURL.path as NSString).abbreviatingWithTildeInPath)")
        exit(0)
      } else {
        print("Error: \(assetWriter.error?.localizedDescription ?? "Unknown error")")
        exit(1)
      }
    }
  }
}

extension CGImage {
  func pngData(compressionFactor: Float) -> Data? {
    NSBitmapImageRep(cgImage: self).representation(
      using: .png, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: compressionFactor])
  }

  func resize(compressionFactor: Float, scale: Float) -> CGImage? {
    guard
      let pngData = pngData(compressionFactor: compressionFactor)
    else {
      return nil
    }
    guard let data = CGImageSourceCreateWithData(pngData as CFData, nil) else {
      return nil
    }
    var maxSideLength = width
    if height > width {
      maxSideLength = height
    }
    maxSideLength = Int(Float(maxSideLength) * scale)
    let options: [String: Any] = [
      kCGImageSourceThumbnailMaxPixelSize as String: maxSideLength,
      kCGImageSourceCreateThumbnailFromImageAlways as String: true,
      kCGImageSourceCreateThumbnailWithTransform as String: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(data, 0, options as CFDictionary)
  }
}

func recordingPid() -> pid_t? {
  let name = ProcessInfo.processInfo.processName
  let task = Process()
  task.launchPath = "/bin/ps"
  task.arguments = ["-A", "-o", "pid,comm"]

  let pipe = Pipe()
  task.standardOutput = pipe
  task.launch()

  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  guard let output = String(data: data, encoding: String.Encoding.utf8) else {
    return nil
  }

  let lines = output.components(separatedBy: "\n")
  for line in lines {
    if line.contains(name) && !line.contains("defunct") {
      let components = line.components(separatedBy: " ")
      let values = components.filter { $0 != "" }
      let found = pid_t(values[0])
      if found != getpid() {
        return found
      }
    }
  }

  return nil
}

func getDesktopFileURL(suffix: String, ext: String) -> URL? {
  let dateFormatter = DateFormatter()
  dateFormatter.dateFormat = "yyyy-MM-dd-HH:mm:ss"
  let timestamp = dateFormatter.string(from: Date())
  let fileName = timestamp + "-" + suffix + ext

  guard var desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
  else { return nil }
  desktopURL.appendPathComponent(fileName)

  return desktopURL
}

func resolveWindowID(_ windowIdentifier: String) -> CGWindowID {
  if let identifier = CGWindowID(windowIdentifier) {
    return identifier
  }
  if let window = NSWorkspace.shared.allWindows(includeHidden: true).filter({
    $0.app.trimmingCharacters(in: .whitespacesAndNewlines)
      .caseInsensitiveCompare(windowIdentifier.trimmingCharacters(in: .whitespacesAndNewlines))
      == .orderedSame
  }).first {
    return CGWindowID(window.identifier)
  }
  print("Error: Invalid window identifier")
  Darwin.exit(1)
}


func createPixelBufferFromCGImage(cgImage: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
  var pixelBuffer: CVPixelBuffer?
  let options: [String: Any] = [
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
  ]

  let status = CVPixelBufferCreate(
    kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, options as CFDictionary,
    &pixelBuffer)
  if status != kCVReturnSuccess {
    return nil
  }

  CVPixelBufferLockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
  let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer!)

  let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
  let context = CGContext(
    data: pixelData, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!), space: rgbColorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)

  if let context = context {
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
  }

  CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))

  return pixelBuffer
}

