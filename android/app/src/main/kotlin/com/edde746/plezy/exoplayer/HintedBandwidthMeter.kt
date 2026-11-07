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

  override fun getBitrateEstimate(): Long {
    val hint = hintBps
    return if (!measured && hint > 0) hint else delegate.bitrateEstimate
  }
}
