package com.edde746.plezy.exoplayer

import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.upstream.BandwidthMeter
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter

/**
 * Atlas adaptive streaming: a bandwidth meter that answers with the app's
 * remembered connection speed ([hintBps]) until it has measured a transfer of
 * its own.
 *
 * ExoPlayer picks the first rendition of an HLS ladder from the meter's
 * estimate. Media3's default starts from a guess per network type, which lands
 * low (or high) no matter how fast this device's connection really was last
 * time; the hint fixes the first pick, and real samples take over from there.
 */
@UnstableApi
internal class HintedBandwidthMeter(
  private val delegate: DefaultBandwidthMeter,
) : BandwidthMeter by delegate {
  @Volatile var hintBps: Long = 0L

  @Volatile private var measured = false

  private val sampleListener = BandwidthMeter.EventListener { _, _, _ -> measured = true }

  init {
    delegate.addEventListener(Handler(Looper.getMainLooper()), sampleListener)
  }

  /** The meter's own measurement, or 0 before it has one (never the hint). */
  val measuredEstimate: Long
    get() = if (measured) delegate.bitrateEstimate else 0L

  // Atlas: a ceiling set after an upswitch stalled playback (see [penalize]).
  @Volatile private var capBps = 0L
  @Volatile private var capUntilMs = 0L
  private var backoffMs = INITIAL_BACKOFF_MS

  /**
   * A switch up to [failedBitrate] made playback stall, so the estimate stays
   * just under that rendition for a while instead of bouncing straight back.
   *
   * The meter measures segments the server already has ready, which arrive at
   * full line speed; a rendition the player hasn't touched yet has to be
   * transcoded first and can't keep up with that number. Each repeat failure
   * doubles the hold (1, 2, 4 ... up to 10 minutes).
   */
  fun penalize(failedBitrate: Long, nowMs: Long) {
    if (failedBitrate <= 0) return
    capBps = (failedBitrate * 0.98).toLong()
    capUntilMs = nowMs + backoffMs
    backoffMs = (backoffMs * 2).coerceAtMost(MAX_BACKOFF_MS)
  }

  /** The ceiling in force right now, or 0. */
  fun activeCap(nowMs: Long): Long = if (capBps > 0 && nowMs < capUntilMs) capBps else 0L

  override fun getBitrateEstimate(): Long {
    val hint = hintBps
    val estimate = if (!measured && hint > 0) hint else delegate.bitrateEstimate
    val cap = activeCap(android.os.SystemClock.elapsedRealtime())
    return if (cap > 0) minOf(estimate, cap) else estimate
  }

  private companion object {
    const val INITIAL_BACKOFF_MS = 60_000L
    const val MAX_BACKOFF_MS = 600_000L
  }
}
