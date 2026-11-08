package com.edde746.plezy.exoplayer

import android.net.Uri
import android.os.SystemClock
import android.util.Log
import androidx.media3.common.Format
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Atlas adaptive streaming: the client-driven warm-up behind every step up.
 *
 * When the track selection decides it can afford a higher rung, it doesn't switch yet. It calls
 * [want] with that rung and the segment it would fetch next. This asks the server (POST
 * `/Videos/{id}/AtlasWarm`) to start transcoding that rung from that segment, and polls about once
 * a second until the server says the next few segments are on disk. Only then does [isReady] let
 * the selection switch, so the switch lands on segments that already exist.
 *
 * Nothing is warmed unless the player actually wants to go up. If it stops wanting (the estimate
 * dropped, or it switched), polling stops and the server lets the unused warm-up die on its own.
 * Dropping down never waits for this.
 */
class AtlasWarmGate {
  private data class Endpoint(
    val baseUrl: String,
    val itemId: String,
    val apiKey: String?,
    val playSessionId: String,
    val headers: Map<String, String>,
  )

  private val executor = Executors.newSingleThreadScheduledExecutor { r ->
    Thread(r, "AtlasWarmGate").apply { isDaemon = true }
  }

  @Volatile private var endpoint: Endpoint? = null
  @Volatile private var levels: Map<String, String> = emptyMap()

  // Written by the loading thread (want), read by the poll thread; guarded by `this`.
  private var targetLevel: String? = null
  private var targetSegment: Long = 0
  private var targetSinceMs: Long = 0
  private var lastWantMs: Long = 0
  private var poll: ScheduledFuture<*>? = null
  private var givenUpLevel: String? = null
  private var givenUpAtMs: Long = 0

  @Volatile private var readyLevel: String? = null
  @Volatile private var readyAtMs: Long = 0

  /**
   * Points the gate at a new playback. [masterUrl] is the Atlas master playlist (`AtlasAbr=true`);
   * any other URL turns the gate off, and the selection then switches freely.
   */
  fun configure(masterUrl: String, headers: Map<String, String>?) {
    reset()
    levels = emptyMap()
    endpoint = null
    val uri = Uri.parse(masterUrl)
    if (uri.getQueryParameter("AtlasAbr")?.equals("true", ignoreCase = true) != true) return
    val path = uri.path ?: return
    val marker = path.indexOf("/Videos/", ignoreCase = true)
    if (marker < 0) return
    val itemId = path.substring(marker + 8).substringBefore('/')
    val playSessionId = uri.getQueryParameter("PlaySessionId") ?: return
    if (itemId.isEmpty()) return
    val port = if (uri.port > 0) ":${uri.port}" else ""
    endpoint = Endpoint(
      baseUrl = "${uri.scheme}://${uri.host}$port${path.substring(0, marker)}",
      itemId = itemId,
      apiKey = uri.getQueryParameter("ApiKey") ?: uri.getQueryParameter("api_key"),
      playSessionId = playSessionId,
      headers = headers ?: emptyMap(),
    )
  }

  /**
   * Maps each rung (by its variant's format) to the server's level id, read from the variant URLs
   * of the loaded master playlist.
   */
  fun setLevels(variants: List<Pair<Format, Uri>>) {
    val map = HashMap<String, String>()
    for ((format, url) in variants) {
      val level = url.getQueryParameter("AtlasLevel") ?: continue
      map[key(format)] = level
    }
    levels = map
  }

  /** Whether the gate is driving this playback (an Atlas master whose levels are known). */
  val isActive: Boolean
    get() = endpoint != null && levels.isNotEmpty()

  /** Whether the server has [format]'s rung transcoded far enough ahead to switch to it now. */
  fun isReady(format: Format): Boolean {
    if (!isActive) return true
    val level = levels[key(format)] ?: return true
    return level == readyLevel && SystemClock.elapsedRealtime() - readyAtMs < READY_TTL_MS
  }

  /**
   * The selection wants to step up to [format], and would fetch [nextSegment] next. Starts (or
   * keeps) the warm-up of that rung; called on every selection pass while the want holds.
   */
  fun want(format: Format, nextSegment: Long) {
    if (!isActive) return
    val level = levels[key(format)] ?: return
    val now = SystemClock.elapsedRealtime()
    synchronized(this) {
      if (level == givenUpLevel && now - givenUpAtMs < GIVE_UP_BACKOFF_MS) return
      if (level != targetLevel) {
        targetLevel = level
        targetSinceMs = now
        readyLevel = null
        Log.i(TAG, "[abr] want ${format.height}p @ ${format.bitrate / 1000} kbps ($level), warming from segment $nextSegment")
      }
      targetSegment = nextSegment
      lastWantMs = now
      if (poll == null) {
        poll = executor.scheduleWithFixedDelay({ pollOnce() }, 0, POLL_INTERVAL_MS, TimeUnit.MILLISECONDS)
      }
    }
  }

  /** Forgets any warm-up in progress (new media, seek). */
  fun reset() {
    synchronized(this) {
      poll?.cancel(false)
      poll = null
      targetLevel = null
      readyLevel = null
      givenUpLevel = null
    }
  }

  fun release() {
    reset()
    executor.shutdownNow()
  }

  private fun pollOnce() {
    val ep = endpoint
    val level: String
    val segment: Long
    val now = SystemClock.elapsedRealtime()
    synchronized(this) {
      val target = targetLevel
      // Nobody has asked for this in a while: the player switched, or no longer wants to go up.
      if (ep == null || target == null || now - lastWantMs > WANT_TTL_MS) {
        poll?.cancel(false)
        poll = null
        targetLevel = null
        return
      }
      if (now - targetSinceMs > GIVE_UP_MS) {
        Log.i(TAG, "[abr] $target didn't warm up in ${GIVE_UP_MS / 1000}s; staying put for a while")
        givenUpLevel = target
        givenUpAtMs = now
        targetLevel = null
        poll?.cancel(false)
        poll = null
        return
      }
      level = target
      segment = targetSegment
    }

    val ready = request(ep!!, level, segment)
    synchronized(this) {
      if (ready && level == targetLevel) {
        if (readyLevel != level) {
          Log.i(TAG, "[abr] $level warmed up after ${(SystemClock.elapsedRealtime() - targetSinceMs)} ms, switching")
        }
        readyLevel = level
        readyAtMs = SystemClock.elapsedRealtime()
      }
    }
  }

  private fun request(ep: Endpoint, level: String, segment: Long): Boolean {
    val url = buildString {
      append(ep.baseUrl).append("/Videos/").append(ep.itemId).append("/AtlasWarm")
      append("?PlaySessionId=").append(Uri.encode(ep.playSessionId))
      append("&Level=").append(Uri.encode(level))
      append("&Segment=").append(segment)
      ep.apiKey?.let { append("&ApiKey=").append(Uri.encode(it)) }
    }
    var connection: HttpURLConnection? = null
    return try {
      connection = (URL(url).openConnection() as HttpURLConnection).apply {
        requestMethod = "POST"
        connectTimeout = 5_000
        readTimeout = 5_000
        doOutput = true
        setFixedLengthStreamingMode(0)
        for ((name, value) in ep.headers) setRequestProperty(name, value)
      }
      connection.outputStream.close()
      if (connection.responseCode !in 200..299) {
        Log.w(TAG, "[abr] warm request for $level failed (${connection.responseCode})")
        return false
      }
      val body = connection.inputStream.bufferedReader().use { it.readText() }
      READY_PATTERN.containsMatchIn(body)
    } catch (e: Exception) {
      Log.w(TAG, "[abr] warm request for $level failed: ${e.message}")
      false
    } finally {
      connection?.disconnect()
    }
  }

  // Every rung has its own bitrate, and the track formats keep the variant's bitrates exactly.
  private fun key(format: Format) = format.bitrate.toString()

  companion object {
    private const val TAG = "ExoPlayerCore"
    private const val POLL_INTERVAL_MS = 1_000L

    /** A ready answer is trusted this long (the selection runs again well within it). */
    private const val READY_TTL_MS = 4_000L

    /** Stop polling once the selection hasn't asked for the target this long. */
    private const val WANT_TTL_MS = 4_000L

    /** A rung that hasn't warmed up in this long isn't keeping up; leave it alone for a while. */
    private const val GIVE_UP_MS = 30_000L
    private const val GIVE_UP_BACKOFF_MS = 60_000L

    private val READY_PATTERN = Regex("\"Ready\"\\s*:\\s*true", RegexOption.IGNORE_CASE)
  }
}
