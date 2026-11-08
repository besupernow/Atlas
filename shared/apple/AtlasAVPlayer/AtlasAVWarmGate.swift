import AVFoundation
import Foundation

/// Atlas adaptive streaming on AVPlayer (iPhone, iPad, Mac): every step up waits for the server.
///
/// The same idea as the ExoPlayer side (`AtlasWarmGate.kt`), shaped for a player that picks its own
/// renditions. AVPlayer can only be steered by a ceiling (`preferredPeakBitRate`), so:
///
/// - Playback opens capped to the lowest rung, the one the server started transcoding when it
///   handed out the playlist.
/// - About once a second this measures the connection (from the access log) and works out the best
///   rung it can carry. When that's above the ceiling, it doesn't raise the ceiling yet: it asks the
///   server to warm that rung up (POST `/Videos/{id}/AtlasWarm`) from where playback is, and stops
///   AVPlayer buffering further ahead on the old rung meanwhile (`preferredForwardBufferDuration`),
///   so the warm-up has a fixed point to catch up to.
/// - Once the server says the rung's next segments are on disk, the ceiling goes up and AVPlayer
///   switches by itself onto segments that already exist.
/// - When AVPlayer drops below the ceiling on its own (the connection got worse), the ceiling
///   follows it down, so the way back up goes through a warm-up too.
/// - A stall soon after a step up puts the ceiling back and leaves that rung alone for a while.
///
/// Nothing is warmed unless the player is about to go up, and nothing at all for a non-Atlas stream.
/// Everything runs on the main thread.
final class AtlasAVWarmGate {
  private struct Level {
    let id: String
    let bandwidth: Double
  }

  private struct Endpoint {
    let baseUrl: String
    let itemId: String
    let apiKey: String?
    let playSessionId: String
    let headers: [String: String]
  }

  /// Logs to the console and the app's log ("[abr] ...", like the Android side).
  var log: ((String) -> Void)?

  private weak var item: AVPlayerItem?
  private var endpoint: Endpoint?
  private var levels: [Level] = []
  private var generation = 0

  private var capIndex = 0
  private var belowCapSince: CFTimeInterval?

  private var estimateBps: Double = 0
  private var lastBytes: Int64 = 0
  private var lastTransferSeconds: Double = 0

  private var targetIndex: Int?
  private var targetSince: CFTimeInterval = 0
  private var requestInFlight = false
  private var holding = false

  private var lastUpswitchAt: CFTimeInterval = 0
  private var lastUpswitchFrom = 0
  private var backoffUntil: [String: CFTimeInterval] = [:]
  private var backoffSeconds: [String: Double] = [:]

  private static let bandwidthFraction = 0.85
  private static let minBufferForUpswitch = 6.0
  private static let holdMinBuffer = 10.0
  private static let giveUpAfter = 30.0
  private static let stallWindow = 30.0

  /// Points the gate at a new playback, before the item is handed to the player. Any URL that
  /// isn't an Atlas adaptive master turns it off (AVPlayer then switches freely, as before).
  func configure(url: URL, headers: [String: String], item: AVPlayerItem) {
    reset()
    generation += 1
    self.item = item
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let query = components.queryItems,
      query.first(where: { $0.name.caseInsensitiveCompare("AtlasAbr") == .orderedSame })?.value?
        .lowercased() == "true",
      let playSessionId = query.first(where: { $0.name == "PlaySessionId" })?.value,
      let range = components.path.range(of: "/Videos/", options: .caseInsensitive)
    else { return }

    let itemId = String(components.path[range.upperBound...].split(separator: "/").first ?? "")
    guard !itemId.isEmpty, let scheme = components.scheme, let host = components.host else { return }
    let port = components.port.map { ":\($0)" } ?? ""
    let prefix = String(components.path[..<range.lowerBound])
    endpoint = Endpoint(
      baseUrl: "\(scheme)://\(host)\(port)\(prefix)",
      itemId: itemId,
      apiKey: query.first(where: { $0.name == "ApiKey" || $0.name == "api_key" })?.value,
      playSessionId: playSessionId,
      headers: headers
    )

    // Until the ladder is known: the start rung's budget, so AVPlayer can't open higher.
    if let start = query.first(where: { $0.name == "AtlasStartBitrate" })?.value.flatMap(Double.init), start > 0 {
      item.preferredPeakBitRate = start
      estimateBps = start
    }
    fetchLadder(url: url, headers: headers, generation: generation)
  }

  func reset() {
    generation += 1
    releaseHold()
    endpoint = nil
    levels = []
    capIndex = 0
    belowCapSince = nil
    estimateBps = 0
    lastBytes = 0
    lastTransferSeconds = 0
    targetIndex = nil
    requestInFlight = false
    lastUpswitchAt = 0
    backoffUntil.removeAll()
    backoffSeconds.removeAll()
  }

  /// A seek: whatever was warming started from the old position.
  func onSeek() {
    if targetIndex != nil { log?("[abr] seek, dropping the warm-up") }
    targetIndex = nil
    releaseHold()
  }

  /// Playback stalled. Right after a step up, that step was too far: back down, and leave that
  /// rung alone for a while (1, 2, 4 ... up to 10 minutes on repeats).
  func onStall() {
    guard endpoint != nil, !levels.isEmpty, lastUpswitchAt > 0,
      CACurrentMediaTime() - lastUpswitchAt < Self.stallWindow
    else { return }
    let failed = levels[capIndex]
    let hold = backoffSeconds[failed.id] ?? 60
    backoffSeconds[failed.id] = min(hold * 2, 600)
    backoffUntil[failed.id] = CACurrentMediaTime() + hold
    log?("[abr] stalled after stepping up to \(failed.id); back to \(levels[lastUpswitchFrom].id) for \(Int(hold))s")
    setCap(lastUpswitchFrom)
    lastUpswitchAt = 0
  }

  /// About once a second while playing.
  func tick(position: Double, bufferedEnd: Double) {
    guard let item, endpoint != nil, !levels.isEmpty, item.status == .readyToPlay else { return }
    let now = CACurrentMediaTime()
    measure(item)
    let buffered = max(0, bufferedEnd - position)

    // AVPlayer went below the ceiling on its own: bring the ceiling down to it.
    if let playing = playingIndex(item), playing < capIndex, targetIndex == nil {
      if let since = belowCapSince {
        if now - since > 4 {
          log?("[abr] AVPlayer dropped to \(levels[playing].id); ceiling follows")
          setCap(playing)
          belowCapSince = nil
        }
      } else {
        belowCapSince = now
      }
    } else {
      belowCapSince = nil
    }

    // The best rung this connection carries.
    var want: Int?
    for index in stride(from: levels.count - 1, to: capIndex, by: -1) {
      let level = levels[index]
      if let until = backoffUntil[level.id], now < until { continue }
      if level.bandwidth <= estimateBps * Self.bandwidthFraction {
        want = index
        break
      }
    }

    guard let want, buffered >= Self.minBufferForUpswitch || targetIndex != nil else {
      if targetIndex != nil, want == nil {
        log?("[abr] connection can't carry \(levels[targetIndex!].id) any more; dropping the warm-up")
        targetIndex = nil
      }
      releaseHold()
      return
    }

    if targetIndex != want {
      targetIndex = want
      targetSince = now
      log?(
        "[abr] want \(levels[want].id) (\(Int(levels[want].bandwidth / 1000)) kbps, estimate \(Int(estimateBps / 1000)) kbps), warming from \(String(format: "%.1f", position))s"
      )
    }
    if now - targetSince > Self.giveUpAfter {
      let level = levels[want]
      log?("[abr] \(level.id) didn't warm up in \(Int(Self.giveUpAfter))s; staying put for a while")
      backoffUntil[level.id] = now + 60
      targetIndex = nil
      releaseHold()
      return
    }

    // Stop running ahead on the old rung while the new one catches up.
    if buffered >= Self.holdMinBuffer && !holding {
      holding = true
      item.preferredForwardBufferDuration = max(buffered, Self.holdMinBuffer)
    }

    // Warm from just ahead of the playhead: AVPlayer may refetch from anywhere it has buffered
    // when it switches, and every one of those segments has to come from the warm transcode.
    requestWarm(index: want, positionSeconds: position + 1)
  }

  // MARK: Ladder

  private func fetchLadder(url: URL, headers: [String: String], generation: Int) {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      let text = data.flatMap { String(data: $0, encoding: .utf8) }
      DispatchQueue.main.async {
        guard let self, generation == self.generation, let text else { return }
        let parsed = Self.parseLevels(text, base: url).sorted { $0.bandwidth < $1.bandwidth }
        guard !parsed.isEmpty else { return }
        self.levels = parsed
        self.setCap(0)
        self.log?("[abr] ladder: " + parsed.map { "\($0.id) \(Int($0.bandwidth / 1000))k" }.joined(separator: ", "))
      }
    }.resume()
  }

  private static func parseLevels(_ text: String, base: URL) -> [Level] {
    var levels: [Level] = []
    var pendingBandwidth: Double?
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#EXT-X-STREAM-INF:") {
        pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap(Double.init)
      } else if !line.isEmpty, !line.hasPrefix("#"), let bandwidth = pendingBandwidth {
        pendingBandwidth = nil
        guard let url = URL(string: line, relativeTo: base),
          let level = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?
            .first(where: { $0.name == "AtlasLevel" })?.value
        else { continue }
        levels.append(Level(id: level, bandwidth: bandwidth))
      }
    }
    return levels
  }

  /// `NAME=value` from an attribute list, not matching inside a longer name (AVERAGE-BANDWIDTH).
  private static func attribute(_ name: String, in line: String) -> String? {
    let body = line.drop(while: { $0 != ":" }).dropFirst()
    for part in body.split(separator: ",") {
      let pair = part.split(separator: "=", maxSplits: 1)
      if pair.count == 2, pair[0] == Substring(name) { return String(pair[1]) }
    }
    return nil
  }

  // MARK: Measuring

  /// Throughput over the last stretch of downloading: bytes over time spent transferring, so idle
  /// time with a full buffer doesn't count as a slow connection.
  private func measure(_ item: AVPlayerItem) {
    guard let events = item.accessLog()?.events, !events.isEmpty else { return }
    var bytes: Int64 = 0
    var seconds = 0.0
    for event in events {
      bytes += max(0, event.numberOfBytesTransferred)
      seconds += max(0, event.transferDuration)
    }
    let deltaBytes = bytes - lastBytes
    let deltaSeconds = seconds - lastTransferSeconds
    guard deltaSeconds > 0.25, deltaBytes > 0 else { return }
    lastBytes = bytes
    lastTransferSeconds = seconds
    let sample = Double(deltaBytes) * 8 / deltaSeconds
    estimateBps = estimateBps > 0 ? estimateBps * 0.6 + sample * 0.4 : sample
  }

  private func playingIndex(_ item: AVPlayerItem) -> Int? {
    guard let indicated = item.accessLog()?.events.last?.indicatedBitrate, indicated > 0 else { return nil }
    var best: Int?
    var bestDistance = Double.greatestFiniteMagnitude
    for (index, level) in levels.enumerated() {
      let distance = abs(level.bandwidth - indicated)
      if distance < bestDistance {
        bestDistance = distance
        best = index
      }
    }
    return best
  }

  // MARK: Ceiling / hold

  private func setCap(_ index: Int) {
    guard let item, levels.indices.contains(index) else { return }
    capIndex = index
    // Just above the rung's BANDWIDTH, so it's allowed and the next one up isn't.
    item.preferredPeakBitRate = levels[index].bandwidth * 1.01
  }

  private func releaseHold() {
    guard holding else { return }
    holding = false
    // 0 = AVPlayer sizes its own forward buffer again.
    item?.preferredForwardBufferDuration = 0
  }

  // MARK: Warm-up requests

  private func requestWarm(index: Int, positionSeconds: Double) {
    guard !requestInFlight, let endpoint, levels.indices.contains(index) else { return }
    let level = levels[index]
    var components = URLComponents(string: "\(endpoint.baseUrl)/Videos/\(endpoint.itemId)/AtlasWarm")
    var query = [
      URLQueryItem(name: "PlaySessionId", value: endpoint.playSessionId),
      URLQueryItem(name: "Level", value: level.id),
      URLQueryItem(name: "PositionTicks", value: String(Int64(max(0, positionSeconds) * 10_000_000))),
    ]
    if let apiKey = endpoint.apiKey { query.append(URLQueryItem(name: "ApiKey", value: apiKey)) }
    components?.queryItems = query
    guard let url = components?.url else { return }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    request.httpMethod = "POST"
    endpoint.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    requestInFlight = true
    let generation = self.generation
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let ready = data.flatMap { String(data: $0, encoding: .utf8) }?
        .range(of: "\"Ready\"\\s*:\\s*true", options: [.regularExpression, .caseInsensitive]) != nil
      DispatchQueue.main.async {
        guard let self, generation == self.generation else { return }
        self.requestInFlight = false
        if status == 404 {
          // The server doesn't know this playback (restarted, or predates warm-ups): switch freely.
          self.log?("[abr] server can't warm up \(level.id) (404); switching without warm-ups for this playback")
          self.releaseHold()
          self.item?.preferredPeakBitRate = 0
          self.endpoint = nil
          return
        }
        if let error {
          self.log?("[abr] warm request for \(level.id) failed: \(error.localizedDescription)")
          return
        }
        guard ready, self.targetIndex == index else { return }
        self.log?("[abr] \(level.id) warmed up after \(Int((CACurrentMediaTime() - self.targetSince) * 1000)) ms, switching")
        self.lastUpswitchFrom = self.capIndex
        self.lastUpswitchAt = CACurrentMediaTime()
        self.targetIndex = nil
        self.setCap(index)
        self.releaseHold()
      }
    }.resume()
  }
}
