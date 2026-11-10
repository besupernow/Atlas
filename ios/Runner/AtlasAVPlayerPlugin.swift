import AVFoundation
import AVKit
import Flutter
import UIKit

/// Atlas: AVPlayer video backend for iPhone and iPad.
///
/// Exists for adaptive streaming. AVPlayer picks and switches HLS renditions
/// from its own bandwidth estimate, which mpv can't, so the Atlas server's
/// quality ladder only works through it.
///
/// Speaks the same channel protocol as the ExoPlayer plugin so the Dart side
/// (`PlayerAvFoundation`, a `PlayerBase`) works unchanged:
/// - property observations come back as `[id, value]`,
/// - lifecycle as `{type: "event", name: "file-loaded" | "playback-restart" | "end-file", data}`.
///
/// Video sits in a view behind the (transparent) Flutter view, the same place
/// the mpv core puts its layer. Subtitles are sidecar text files fetched and
/// drawn here, since nothing is burned into an adaptive stream.
///
/// Rendition switching goes through `AtlasAVWarmGate` (shared with the Mac): AVPlayer
/// only steps up once the server has the higher rung transcoding ahead of it.
final class AtlasAVPlayerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var nameToId: [String: Int] = [:]
  private var core: AtlasAVPlayerCore?
  /// The Dart instance that created [core]; a dispose from any other is stale.
  private var coreOwner: Int?

  static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(name: "com.atlas/av_player", binaryMessenger: registrar.messenger())
    let eventChannel = FlutterEventChannel(name: "com.atlas/av_player/events", binaryMessenger: registrar.messenger())
    let pipChannel = FlutterMethodChannel(name: "com.atlas/av_pip", binaryMessenger: registrar.messenger())
    let instance = AtlasAVPlayerPlugin()
    instance.pipChannel = pipChannel
    // Coming back to the app ends Picture in Picture: the video goes back into the player.
    NotificationCenter.default.addObserver(
      instance, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification,
      object: nil)
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
    pipChannel.setMethodCallHandler { [weak instance] call, result in
      DispatchQueue.main.async { instance?.handlePip(call, result) ?? result(nil) }
    }
  }

  // MARK: Picture in Picture

  private var pipChannel: FlutterMethodChannel?
  private var pipController: AVPictureInPictureController?

  private func handlePip(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(AVPictureInPictureController.isPictureInPictureSupported() && core != nil)
    case "enter":
      guard let controller = ensurePipController() else {
        result(["success": false, "errorCode": "not_supported"])
        return
      }
      guard controller.isPictureInPicturePossible else {
        result(["success": false, "errorCode": "pip_prepare_failed"])
        return
      }
      controller.startPictureInPicture()
      result(["success": true])
    case "exit":
      pipController?.stopPictureInPicture()
      result(nil)
    case "setAutoPipReady":
      let ready = (call.arguments as? [String: Any])?["ready"] as? Bool ?? false
      if let controller = ensurePipController() {
        controller.canStartPictureInPictureAutomaticallyFromInline = ready
      }
      result(nil)
    default:
      result(nil)
    }
  }

  @objc private func appWillEnterForeground() {
    guard let pipController, pipController.isPictureInPictureActive else { return }
    pipController.stopPictureInPicture()
  }

  private func ensurePipController() -> AVPictureInPictureController? {
    guard AVPictureInPictureController.isPictureInPictureSupported(), let layer = core?.videoLayer else { return nil }
    if let pipController, pipController.playerLayer === layer { return pipController }
    let controller = AVPictureInPictureController(playerLayer: layer)
    controller?.delegate = self
    pipController = controller
    return controller
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emitProperty(_ name: String, _ value: Any?) {
    guard let id = nameToId[name], let sink = eventSink else { return }
    sink([id, value ?? NSNull()])
  }

  private func emitEvent(_ name: String, _ data: [String: Any]? = nil) {
    guard let sink = eventSink else { return }
    var event: [String: Any] = ["type": "event", "name": name]
    if let data { event["data"] = data }
    sink(event)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(nil)
        return
      }
      self.dispatch(call.method, args, result)
    }
  }

  private func dispatch(_ method: String, _ args: [String: Any], _ result: @escaping FlutterResult) {
    switch method {
    case "initialize":
      if let core, core.isInitialized {
        coreOwner = args["instanceId"] as? Int ?? coreOwner
        result(true)
        return
      }
      guard let window = ExternalDisplayManager.mainApplicationWindow() else {
        result(FlutterError(code: "NO_WINDOW", message: "Could not find the app window", details: nil))
        return
      }
      let core = AtlasAVPlayerCore()
      core.onProperty = { [weak self] name, value in self?.emitProperty(name, value) }
      core.onEvent = { [weak self] name, data in self?.emitEvent(name, data) }
      core.initialize(in: window)
      self.core = core
      coreOwner = args["instanceId"] as? Int
      result(true)

    case "dispose":
      let instanceId = args["instanceId"] as? Int
      if let instanceId, let coreOwner, instanceId != coreOwner {
        result(nil)
        return
      }
      pipController?.stopPictureInPicture()
      pipController = nil
      core?.dispose()
      core = nil
      coreOwner = nil
      nameToId.removeAll()
      result(nil)

    case "isInitialized":
      result(core?.isInitialized ?? false)

    case "observeProperty":
      if let name = args["name"] as? String, let id = args["id"] as? Int {
        nameToId[name] = id
        core?.republish(name)
      }
      result(nil)

    case "open":
      guard let core, let uri = args["uri"] as? String else {
        result(FlutterError(code: "NOT_READY", message: "open before initialize, or no uri", details: nil))
        return
      }
      core.open(
        uri: uri,
        headers: args["headers"] as? [String: String] ?? [:],
        startMs: (args["startPositionMs"] as? NSNumber)?.int64Value ?? 0,
        autoPlay: args["autoPlay"] as? Bool ?? true,
        subtitles: args["externalSubtitles"] as? [[String: Any]] ?? []
      )
      result(nil)

    case "play":
      core?.play()
      result(nil)
    case "pause":
      core?.pause()
      result(nil)
    case "stop":
      core?.stop()
      result(nil)
    case "seek":
      let ms = (args["positionMs"] as? NSNumber)?.int64Value ?? 0
      guard let core else {
        result(nil)
        return
      }
      core.seek(ms: ms) { result(nil) }
    case "setVolume":
      core?.setVolume((args["volume"] as? NSNumber)?.doubleValue ?? 100)
      result(nil)
    case "setRate":
      core?.setRate((args["rate"] as? NSNumber)?.doubleValue ?? 1)
      result(nil)
    case "selectAudioTrack":
      // An adaptive stream carries one (muxed) audio track; switching audio is a reload.
      result(nil)
    case "selectSubtitleTrack":
      core?.selectSubtitle(id: args["trackId"] as? String ?? "no")
      result(nil)
    case "setSubtitleRendering":
      core?.setSubtitleRendering(args["enabled"] as? Bool ?? true)
      result(nil)
    case "setSubtitleDelay":
      core?.subtitleDelay = (args["seconds"] as? NSNumber)?.doubleValue ?? 0
      result(nil)
    case "setSubtitleStyle":
      core?.applySubtitleStyle(args)
      result(nil)
    case "setBoxFitMode":
      core?.setBoxFit((args["mode"] as? NSNumber)?.intValue ?? 0)
      result(nil)
    case "setVideoZoom":
      core?.setZoom((args["scale"] as? NSNumber)?.doubleValue ?? 1)
      result(nil)
    case "setVisible":
      core?.setVisible(args["visible"] as? Bool ?? true)
      result(nil)
    case "updateFrame":
      core?.updateFrame()
      result(nil)
    case "getStats":
      result(core?.stats() ?? [:])
    case "getPlayerType":
      result("avplayer")
    default:
      // mpv / ExoPlayer specific calls have nothing to do here.
      result(nil)
    }
  }
}

extension AtlasAVPlayerPlugin: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    pipChannel?.invokeMethod("onPipChanged", arguments: true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    core?.updateFrame()
    pipChannel?.invokeMethod("onPipChanged", arguments: false)
  }

  /// The "back to the app" button in the PiP window: the player is still there, so say yes and let
  /// the video animate back into it.
  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    core?.setVisible(true)
    completionHandler(core != nil)
  }
}

// MARK: - Core

final class AtlasAVPlayerCore: NSObject {
  var onProperty: ((String, Any?) -> Void)?
  var onEvent: ((String, [String: Any]?) -> Void)?
  private(set) var isInitialized = false

  private let player = AVPlayer()
  private let container = UIView()
  private let playerLayer = AVPlayerLayer()
  var videoLayer: AVPlayerLayer { playerLayer }
  private let subtitleLabel = UILabel()
  private weak var window: UIWindow?

  private var item: AVPlayerItem?
  private var itemObservations: [NSKeyValueObservation] = []
  private var playerObservations: [NSKeyValueObservation] = []
  private var itemTokens: [NSObjectProtocol] = []
  private var globalTokens: [NSObjectProtocol] = []
  private var timeObserver: Any?

  /// Bumped on every open, so callbacks from a replaced item are dropped.
  private var generation = 0
  private var wantsPlay = false
  private var desiredRate: Float = 1
  /// Whether this item has started playing once (see startPlayback).
  private var startedOnce = false
  private var pendingStart: CMTime?
  private var fileLoaded = false
  private var restartSent = false
  private var lastTimeEmit: CFTimeInterval = 0
  private var lastBuffering: Bool?

  // Atlas adaptive streaming: when to step up (see AtlasAVWarmGate).
  private let abr = AtlasAVWarmGate()
  private var lastAbrTick: CFTimeInterval = 0
  private var lastSeekAt: CFTimeInterval = 0

  // Subtitles
  private struct Cue {
    let start: Double
    let end: Double
    let text: String
  }

  private struct Sidecar {
    let id: String
    let uri: String
    let title: String?
    let language: String?
    let codec: String?
    let isDefault: Bool
    let isForced: Bool
  }

  private var sidecars: [Sidecar] = []
  private var cuesById: [String: [Cue]] = [:]
  private var selectedSubtitleId: String?
  private var shownCueText: String?
  /// False while the app draws subtitles itself (AtlasSubtitleOverlay).
  private var drawsSubtitles = true
  var subtitleDelay: Double = 0
  private var subtitleFontSize: CGFloat = 55
  private var subtitleTextColor: UIColor = .white
  private var subtitleBorderColor: UIColor = .black
  private var subtitleBorderSize: CGFloat = 3
  private var subtitleBold = false
  private var subtitleBottomMargin: CGFloat = 0.06

  func initialize(in window: UIWindow) {
    self.window = window
    container.frame = window.bounds
    container.backgroundColor = .black
    container.isUserInteractionEnabled = false
    container.isHidden = true

    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    playerLayer.backgroundColor = UIColor.black.cgColor
    container.layer.addSublayer(playerLayer)

    subtitleLabel.numberOfLines = 0
    subtitleLabel.textAlignment = .center
    subtitleLabel.isHidden = true
    container.addSubview(subtitleLabel)

    window.insertSubview(container, at: 0)
    layoutViews()

    player.automaticallyWaitsToMinimizeStalling = true
    player.appliesMediaSelectionCriteriaAutomatically = false
    player.allowsExternalPlayback = true

    abr.log = { [weak self] text in
      NSLog("[AtlasAVPlayer] %@", text)
      self?.onEvent?("log-message", ["prefix": "avplayer", "level": "info", "text": text])
    }

    let interval = CMTime(value: 1, timescale: 10)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
      self?.onTick(time)
    }

    playerObservations.append(
      player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
        DispatchQueue.main.async { self?.onTimeControlStatus(player) }
      })
    playerObservations.append(
      playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
        DispatchQueue.main.async {
          guard let self, layer.isReadyForDisplay else { return }
          self.sendRestartIfNeeded()
        }
      })

    globalTokens.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let self,
          let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .began
        else { return }
        self.wantsPlay = false
        self.onProperty?("pause", true)
      })

    isInitialized = true
  }

  /// Re-sends the current value of a property Dart just started observing.
  func republish(_ name: String) {
    switch name {
    case "pause": onProperty?("pause", !wantsPlay)
    case "volume": onProperty?("volume", Double(player.volume) * 100)
    case "speed": onProperty?("speed", Double(desiredRate))
    case "track-list": emitTrackList()
    default: break
    }
  }

  // MARK: Open / transport

  func open(uri: String, headers: [String: String], startMs: Int64, autoPlay: Bool, subtitles: [[String: Any]]) {
    generation += 1
    let gen = generation
    teardownItem()

    guard let url = URL(string: uri) else {
      onEvent?("end-file", ["reason": 4, "message": "Invalid URL"])
      return
    }

    fileLoaded = false
    startedOnce = false
    restartSent = false
    lastBuffering = nil
    wantsPlay = autoPlay
    pendingStart = startMs > 0 ? CMTime(value: startMs, timescale: 1000) : nil

    sidecars = subtitles.enumerated().compactMap { index, raw -> Sidecar? in
      guard let subUri = raw["uri"] as? String, !subUri.isEmpty else { return nil }
      return Sidecar(
        id: "\(index + 1)",
        uri: subUri,
        title: raw["title"] as? String,
        language: raw["language"] as? String,
        codec: raw["codec"] as? String,
        isDefault: raw["isDefault"] as? Bool ?? false,
        isForced: raw["isForced"] as? Bool ?? false
      )
    }
    cuesById.removeAll()
    selectedSubtitleId = nil
    showCue(nil)

    var options: [String: Any] = [:]
    if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    // 0 = let AVPlayer size its own forward buffer, which it ties to its ABR choices.
    item.preferredForwardBufferDuration = 0
    self.item = item
    // Atlas: opens capped to the start rung; steps up only once the server has warmed the next.
    abr.configure(url: url, headers: headers, item: item)

    itemObservations.append(
      item.observe(\.status, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async { self?.onItemStatus(item, gen) }
      })
    itemObservations.append(
      item.observe(\.duration, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async { self?.emitDuration(item, gen) }
      })
    itemObservations.append(
      item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async { self?.emitCache(item, gen) }
      })

    itemTokens.append(
      NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
      ) { [weak self] _ in
        guard let self, gen == self.generation else { return }
        self.wantsPlay = false
        self.onProperty?("eof-reached", true)
      })
    itemTokens.append(
      NotificationCenter.default.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
      ) { [weak self] note in
        guard let self, gen == self.generation else { return }
        let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        self.fail(error?.localizedDescription ?? "Playback failed")
      })

    onProperty?("eof-reached", false)
    onProperty?("seekable", false)
    onProperty?("pause", !autoPlay)
    emitTrackList()
    onProperty?("sid", "no")

    player.replaceCurrentItem(with: item)
  }

  private func onItemStatus(_ item: AVPlayerItem, _ gen: Int) {
    guard gen == generation else { return }
    switch item.status {
    case .readyToPlay:
      guard !fileLoaded else { return }
      fileLoaded = true
      disableAutomaticSubtitles(item)
      activateAudioSession()
      onEvent?("file-loaded", nil)
      emitDuration(item, gen)
      emitTrackList()
      if let start = pendingStart {
        pendingStart = nil
        item.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
          DispatchQueue.main.async {
            guard let self, gen == self.generation else { return }
            if self.wantsPlay { self.startPlayback() }
          }
        }
      } else if wantsPlay {
        startPlayback()
      }
    case .failed:
      fail(item.error?.localizedDescription ?? "Could not load the stream")
    default:
      break
    }
  }

  /// Atlas: no subtitles from AVPlayer itself. It would otherwise pick a subtitle rendition (or
  /// iOS's machine-generated captions) on its own, which shows up in Picture in Picture. The app
  /// draws the subtitle the viewer chose from the sidecar files.
  private func disableAutomaticSubtitles(_ item: AVPlayerItem) {
    let asset = item.asset
    if #available(iOS 16, *) {
      Task { @MainActor [weak item] in
        guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
        item?.select(nil, in: group)
      }
    } else if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
      item.select(nil, in: group)
    }
  }

  private func fail(_ message: String) {
    NSLog("[AtlasAVPlayer] %@", message)
    onEvent?("log-message", ["prefix": "avplayer", "level": "error", "text": message])
    onEvent?("end-file", ["reason": 4, "message": message])
  }

  func play() {
    wantsPlay = true
    activateAudioSession()
    // A finished item restarts from the top, like mpv's play after eof.
    if let item, item.duration.isNumeric, CMTimeCompare(item.currentTime(), item.duration) >= 0 {
      player.seek(to: .zero)
      onProperty?("eof-reached", false)
    }
    if fileLoaded && pendingStart == nil { startPlayback() }
    onProperty?("pause", false)
  }

  func pause() {
    wantsPlay = false
    player.pause()
    onProperty?("pause", true)
  }

  func stop() {
    generation += 1
    abr.reset()
    wantsPlay = false
    player.pause()
    teardownItem()
    player.replaceCurrentItem(with: nil)
    showCue(nil)
    onEvent?("end-file", ["reason": 2])
  }

  func seek(ms: Int64, completion: @escaping () -> Void) {
    let gen = generation
    let target = CMTime(value: max(ms, 0), timescale: 1000)
    if !fileLoaded {
      // Not ready yet: the open's own start seek takes it.
      pendingStart = target
      completion()
      return
    }
    onProperty?("eof-reached", false)
    lastSeekAt = CACurrentMediaTime()
    abr.onSeek()
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      DispatchQueue.main.async {
        completion()
        guard let self, finished, gen == self.generation else { return }
        self.onProperty?("time-pos", target.seconds)
        self.onEvent?("playback-restart", nil)
        self.updateSubtitle(at: target.seconds)
      }
    }
  }

  func setVolume(_ volume: Double) {
    player.volume = Float(max(0, min(volume, 100)) / 100)
  }

  func setRate(_ rate: Double) {
    desiredRate = Float(rate)
    if player.rate != 0 { player.rate = desiredRate }
  }

  /// Starts playback at the chosen speed (AVPlayer.play() always means 1x before iOS 16).
  ///
  /// The first start of an item doesn't wait for AVPlayer's "likely to keep up"
  /// verdict, which wants several segments buffered: the stream opens on its
  /// lowest rung, one segment is enough, and AVPlayer climbs from there.
  private func startPlayback() {
    if !startedOnce {
      startedOnce = true
      player.playImmediately(atRate: desiredRate)
      return
    }
    player.play()
    if desiredRate != 1 { player.rate = desiredRate }
  }

  // MARK: Item / player observation

  private func onTick(_ time: CMTime) {
    guard item != nil else { return }
    let seconds = time.seconds
    guard seconds.isFinite else { return }
    let now = CACurrentMediaTime()
    if now - lastTimeEmit >= 0.25 {
      lastTimeEmit = now
      onProperty?("time-pos", seconds)
    }
    if now - lastAbrTick >= 1, let item {
      lastAbrTick = now
      abr.tick(position: seconds, bufferedEnd: Self.bufferedEnd(item, at: seconds))
    }
    updateSubtitle(at: seconds)
  }

  /// The end of the buffered range playback is in (or the position, if none).
  private static func bufferedEnd(_ item: AVPlayerItem, at seconds: Double) -> Double {
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      let start = range.start.seconds
      let end = (range.start + range.duration).seconds
      if seconds >= start - 0.5 && seconds <= end + 0.5 { return end }
    }
    return seconds
  }

  private func onTimeControlStatus(_ player: AVPlayer) {
    let waiting =
      player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      && player.reasonForWaitingToPlay != AVPlayer.WaitingReason.noItemToPlay
    let buffering = wantsPlay && waiting
    if lastBuffering != buffering {
      // A stall mid-play (not the start, not a seek) right after a step up backs the step out.
      if buffering, restartSent, CACurrentMediaTime() - lastSeekAt > 3 { abr.onStall() }
      lastBuffering = buffering
      onProperty?("paused-for-cache", buffering)
    }
    if player.timeControlStatus == .playing { sendRestartIfNeeded() }
  }

  private func sendRestartIfNeeded() {
    guard fileLoaded, !restartSent, playerLayer.isReadyForDisplay else { return }
    restartSent = true
    onEvent?("playback-restart", nil)
  }

  private func emitDuration(_ item: AVPlayerItem, _ gen: Int) {
    guard gen == generation else { return }
    let duration = item.duration
    if duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 {
      onProperty?("duration", duration.seconds)
      onProperty?("seekable", true)
    }
  }

  private func emitCache(_ item: AVPlayerItem, _ gen: Int) {
    guard gen == generation else { return }
    let now = item.currentTime().seconds
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      let start = range.start.seconds
      let end = (range.start + range.duration).seconds
      if now >= start - 0.5 && now <= end + 0.5 {
        onProperty?("demuxer-cache-time", end)
        return
      }
    }
  }

  private func teardownItem() {
    itemObservations.forEach { $0.invalidate() }
    itemObservations.removeAll()
    itemTokens.forEach { NotificationCenter.default.removeObserver($0) }
    itemTokens.removeAll()
    item = nil
  }

  private func activateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)
  }

  // MARK: Tracks

  private func emitTrackList() {
    var tracks: [[String: Any]] = [
      ["id": "1", "type": "video", "selected": true],
      ["id": "1", "type": "audio", "selected": true, "default": true],
    ]
    for sidecar in sidecars {
      var track: [String: Any] = [
        "id": sidecar.id,
        "type": "sub",
        "external": true,
        "external-filename": sidecar.uri,
        "default": sidecar.isDefault,
        "forced": sidecar.isForced,
        "selected": sidecar.id == selectedSubtitleId,
      ]
      if let title = sidecar.title { track["title"] = title }
      if let language = sidecar.language { track["lang"] = language }
      if let codec = sidecar.codec { track["codec"] = codec }
      tracks.append(track)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: tracks),
      let json = String(data: data, encoding: .utf8)
    else { return }
    onProperty?("track-list", json)
    onProperty?("aid", "1")
  }

  // MARK: Subtitles

  func setSubtitleRendering(_ enabled: Bool) {
    drawsSubtitles = enabled
    if enabled {
      if let id = selectedSubtitleId, cuesById[id] == nil, let sidecar = sidecars.first(where: { $0.id == id }) {
        loadCues(for: sidecar)
      }
      updateSubtitle(at: player.currentTime().seconds)
    } else {
      showCue(nil)
    }
  }

  func selectSubtitle(id: String) {
    guard let sidecar = sidecars.first(where: { $0.id == id }) else {
      selectedSubtitleId = nil
      showCue(nil)
      onProperty?("sid", "no")
      emitTrackList()
      return
    }
    selectedSubtitleId = sidecar.id
    onProperty?("sid", sidecar.id)
    emitTrackList()
    if drawsSubtitles && cuesById[sidecar.id] == nil { loadCues(for: sidecar) }
  }

  private func loadCues(for sidecar: Sidecar) {
    guard let url = URL(string: Self.webVttUrl(sidecar.uri)) else { return }
    let gen = generation
    URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
      let text = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }
      let cues = text.map(Self.parseCues) ?? []
      DispatchQueue.main.async {
        guard let self, gen == self.generation else { return }
        if let error {
          self.onEvent?(
            "log-message",
            ["prefix": "avplayer", "level": "warn", "text": "Subtitle load failed: \(error.localizedDescription)"])
        }
        self.cuesById[sidecar.id] = cues
        self.updateSubtitle(at: self.player.currentTime().seconds)
      }
    }.resume()
  }

  /// Jellyfin converts subtitles on the fly; asking for `.vtt` gets one format to parse.
  private static func webVttUrl(_ uri: String) -> String {
    guard var components = URLComponents(string: uri) else { return uri }
    let path = components.path
    if let range = path.range(
      of: "/Stream\\.(srt|subrip|ass|ssa|sub|vtt|webvtt)$", options: [.regularExpression, .caseInsensitive])
    {
      components.path = path.replacingCharacters(in: range, with: "/Stream.vtt")
    }
    return components.url?.absoluteString ?? uri
  }

  /// Parses WebVTT (and SRT, which has the same cue shape) into plain-text cues.
  private static func parseCues(_ text: String) -> [Cue] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var cues: [Cue] = []
    for block in normalized.components(separatedBy: "\n\n") {
      let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
      let parts = lines[timingIndex].components(separatedBy: "-->")
      guard parts.count == 2,
        let start = parseTime(parts[0]),
        let end = parseTime(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
      else { continue }
      let body = lines[(timingIndex + 1)...]
        .map(cleanCueLine)
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
    }
    return cues.sorted { $0.start < $1.start }
  }

  private static func parseTime(_ raw: String) -> Double? {
    let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    let fields = value.split(separator: ":").map(String.init)
    guard (2...3).contains(fields.count) else { return nil }
    var seconds = 0.0
    for field in fields {
      guard let number = Double(field) else { return nil }
      seconds = seconds * 60 + number
    }
    return seconds
  }

  private static func cleanCueLine(_ line: String) -> String {
    line
      .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\N", with: "\n")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  private func updateSubtitle(at seconds: Double) {
    guard drawsSubtitles, let id = selectedSubtitleId, let cues = cuesById[id], seconds.isFinite else {
      showCue(nil)
      return
    }
    let time = seconds - subtitleDelay
    let active = cues.filter { $0.start <= time && time < $0.end }.map(\.text)
    showCue(active.isEmpty ? nil : active.joined(separator: "\n"))
  }

  private func showCue(_ text: String?) {
    guard text != shownCueText else { return }
    shownCueText = text
    guard let text else {
      subtitleLabel.isHidden = true
      subtitleLabel.attributedText = nil
      return
    }
    subtitleLabel.attributedText = attributedCue(text)
    subtitleLabel.isHidden = false
    layoutSubtitle()
  }

  private func attributedCue(_ text: String) -> NSAttributedString {
    // mpv's sub-font-size is in "scaled pixels" of a 720-line frame; keep the same feel.
    let height = max(container.bounds.height, 1)
    let size = max(12, subtitleFontSize * height / 720 * 0.72)
    let font = subtitleBold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size, weight: .semibold)
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.black.withAlphaComponent(0.8)
    shadow.shadowBlurRadius = 3
    shadow.shadowOffset = CGSize(width: 0, height: 1)
    return NSAttributedString(
      string: text,
      attributes: [
        .font: font,
        .foregroundColor: subtitleTextColor,
        .strokeColor: subtitleBorderColor,
        .strokeWidth: -subtitleBorderSize,
        .shadow: shadow,
      ])
  }

  func applySubtitleStyle(_ args: [String: Any]) {
    if let size = (args["fontSize"] as? NSNumber)?.doubleValue, size > 0 { subtitleFontSize = CGFloat(size) }
    if let color = (args["textColor"] as? String).flatMap(Self.color) { subtitleTextColor = color }
    if let color = (args["borderColor"] as? String).flatMap(Self.color) { subtitleBorderColor = color }
    if let border = (args["borderSize"] as? NSNumber)?.doubleValue { subtitleBorderSize = CGFloat(max(0, border)) }
    subtitleBold = args["bold"] as? Bool ?? false
    if let position = (args["subtitlePosition"] as? NSNumber)?.doubleValue {
      // 100 = bottom, smaller moves up (mpv's sub-pos).
      subtitleBottomMargin = CGFloat(max(0.02, min(0.9, 0.06 + (100 - position) / 100)))
    }
    if let text = shownCueText { subtitleLabel.attributedText = attributedCue(text) }
    layoutSubtitle()
  }

  /// `#RRGGBB` or `#AARRGGBB`.
  private static func color(_ hex: String) -> UIColor? {
    var value = hex.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("#") { value.removeFirst() }
    guard let number = UInt64(value, radix: 16) else { return nil }
    switch value.count {
    case 6:
      return UIColor(
        red: CGFloat((number >> 16) & 0xFF) / 255, green: CGFloat((number >> 8) & 0xFF) / 255,
        blue: CGFloat(number & 0xFF) / 255, alpha: 1)
    case 8:
      return UIColor(
        red: CGFloat((number >> 16) & 0xFF) / 255, green: CGFloat((number >> 8) & 0xFF) / 255,
        blue: CGFloat(number & 0xFF) / 255, alpha: CGFloat((number >> 24) & 0xFF) / 255)
    default:
      return nil
    }
  }

  // MARK: Layout

  func setVisible(_ visible: Bool) {
    container.isHidden = !visible
    if visible { updateFrame() }
  }

  func updateFrame() {
    if let superview = container.superview {
      container.frame = superview.bounds
    } else if let window {
      container.frame = window.bounds
    }
    layoutViews()
  }

  private func layoutViews() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.bounds = CGRect(origin: .zero, size: container.bounds.size)
    playerLayer.position = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
    CATransaction.commit()
    layoutSubtitle()
  }

  private func layoutSubtitle() {
    let bounds = container.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }
    let maxWidth = bounds.width * 0.9
    let size = subtitleLabel.sizeThatFits(CGSize(width: maxWidth, height: bounds.height))
    let bottom = bounds.height * (1 - subtitleBottomMargin)
    subtitleLabel.frame = CGRect(
      x: (bounds.width - size.width) / 2, y: bottom - size.height, width: size.width, height: size.height)
  }

  func setBoxFit(_ mode: Int) {
    switch mode {
    case 1: playerLayer.videoGravity = .resizeAspectFill
    case 2: playerLayer.videoGravity = .resize
    default: playerLayer.videoGravity = .resizeAspect
    }
  }

  func setZoom(_ scale: Double) {
    let clamped = CGFloat(min(max(scale, 0.25), 4.0))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.setAffineTransform(CGAffineTransform(scaleX: clamped, y: clamped))
    CATransaction.commit()
  }

  // MARK: Stats

  /// ExoPlayer-shaped stats, so the performance overlay shows the rendition in play.
  func stats() -> [String: Any] {
    var out: [String: Any] = ["playerType": "avplayer"]
    guard let item else { return out }
    let size = item.presentationSize
    if size.width > 0 { out["videoWidth"] = Int(size.width) }
    if size.height > 0 { out["videoHeight"] = Int(size.height) }
    if let fps = item.tracks.map({ $0.currentVideoFrameRate }).first(where: { $0 > 0 }) {
      out["videoFps"] = Double(fps)
    }
    if let event = item.accessLog()?.events.last {
      if event.indicatedBitrate > 0 { out["videoBitrate"] = Int(event.indicatedBitrate) }
      out["videoDroppedFrames"] = event.numberOfDroppedVideoFrames
      let observedMbps = event.observedBitrate > 0 ? String(format: "%.1f", event.observedBitrate / 1_000_000) : "?"
      out["videoDecoderName"] = "AVPlayer HLS, \(event.numberOfMediaRequests) segments, est. \(observedMbps) Mbps"
      out["switches"] = event.switchBitrate
      // Atlas: the measured connection speed, remembered for the next play's start level.
      if event.observedBitrate > 0 { out["bandwidthEstimate"] = Int(event.observedBitrate) }
    }
    let now = item.currentTime().seconds
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      let end = (range.start + range.duration).seconds
      if now >= range.start.seconds - 0.5 && now <= end {
        out["totalBufferedDurationMs"] = Int(max(0, end - now) * 1000)
      }
    }
    return out
  }

  // MARK: Teardown

  func dispose() {
    generation += 1
    abr.reset()
    player.pause()
    teardownItem()
    player.replaceCurrentItem(with: nil)
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    playerObservations.forEach { $0.invalidate() }
    playerObservations.removeAll()
    globalTokens.forEach { NotificationCenter.default.removeObserver($0) }
    globalTokens.removeAll()
    container.removeFromSuperview()
    isInitialized = false
  }
}
