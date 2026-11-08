package com.edde746.plezy.exoplayer

import androidx.media3.common.Format
import androidx.media3.common.TrackGroup
import androidx.media3.common.util.Clock
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.trackselection.AdaptiveTrackSelection
import androidx.media3.exoplayer.upstream.BandwidthMeter
import com.google.common.collect.ImmutableList

/**
 * Atlas adaptive streaming: ExoPlayer's adaptive selection, but it only ever steps up one rung at a
 * time (dropping down is unrestricted).
 *
 * Every rung above the one playing is a transcode the server hasn't been asked for by the player
 * yet. The server keeps the next rung up warm (already transcoding a little ahead), so stepping to
 * it is smooth; jumping from 480p straight to 1080p would land on a cold transcoder and stall while
 * the buffer drains. Climbing rung by rung also lets each step prove itself before the next.
 */
@UnstableApi
class SteppedAdaptiveTrackSelection(
  group: TrackGroup,
  tracks: IntArray,
  type: Int,
  bandwidthMeter: BandwidthMeter,
  minDurationForQualityIncreaseMs: Long,
  maxDurationForQualityDecreaseMs: Long,
  minDurationToRetainAfterDiscardMs: Long,
  bandwidthFraction: Float,
  adaptationCheckpoints: List<AdaptationCheckpoint>,
) : AdaptiveTrackSelection(
  group,
  tracks,
  type,
  bandwidthMeter,
  minDurationForQualityIncreaseMs,
  maxDurationForQualityDecreaseMs,
  minDurationToRetainAfterDiscardMs,
  DEFAULT_MAX_WIDTH_TO_DISCARD,
  DEFAULT_MAX_HEIGHT_TO_DISCARD,
  bandwidthFraction,
  DEFAULT_BUFFERED_FRACTION_TO_LIVE_EDGE_FOR_QUALITY_INCREASE,
  adaptationCheckpoints,
  Clock.DEFAULT,
) {
  override fun canSelectFormat(format: Format, trackBitrate: Int, effectiveBitrate: Long): Boolean {
    // During construction (the first pick) there is no "current" rung yet; the base class then
    // reads as the top rung, so nothing is held back and the start estimate decides.
    val current = selectedFormat
    if (current.bitrate > 0 && format.bitrate > current.bitrate) {
      var nextUp = Int.MAX_VALUE
      for (i in 0 until length()) {
        val bitrate = getFormat(i).bitrate
        if (bitrate > current.bitrate && bitrate < nextUp) nextUp = bitrate
      }
      if (format.bitrate > nextUp) return false
    }
    return super.canSelectFormat(format, trackBitrate, effectiveBitrate)
  }

  /** Builds [SteppedAdaptiveTrackSelection]s with the given tuning. */
  class Factory(
    private val minDurationForQualityIncreaseMs: Long,
    private val maxDurationForQualityDecreaseMs: Long,
    private val minDurationToRetainAfterDiscardMs: Long,
    private val bandwidthFraction: Float,
  ) : AdaptiveTrackSelection.Factory(
    minDurationForQualityIncreaseMs.toInt(),
    maxDurationForQualityDecreaseMs.toInt(),
    minDurationToRetainAfterDiscardMs.toInt(),
    bandwidthFraction,
  ) {
    override fun createAdaptiveTrackSelection(
      group: TrackGroup,
      tracks: IntArray,
      type: Int,
      bandwidthMeter: BandwidthMeter,
      adaptationCheckpoints: ImmutableList<AdaptationCheckpoint>,
    ): AdaptiveTrackSelection = SteppedAdaptiveTrackSelection(
      group,
      tracks,
      type,
      bandwidthMeter,
      minDurationForQualityIncreaseMs,
      maxDurationForQualityDecreaseMs,
      minDurationToRetainAfterDiscardMs,
      bandwidthFraction,
      adaptationCheckpoints,
    )
  }
}
