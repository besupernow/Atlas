package com.edde746.plezy.exoplayer

import androidx.media3.common.Format
import androidx.media3.common.TrackGroup
import androidx.media3.common.util.Clock
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.source.chunk.MediaChunk
import androidx.media3.exoplayer.source.chunk.MediaChunkIterator
import androidx.media3.exoplayer.trackselection.AdaptiveTrackSelection
import androidx.media3.exoplayer.upstream.BandwidthMeter
import com.google.common.collect.ImmutableList

/**
 * Atlas adaptive streaming: ExoPlayer's adaptive selection, where every step up waits for the server.
 *
 * ExoPlayer still decides what it can afford, and it may jump several rungs at once. But a rung
 * above the one loading is a transcode that may not be running yet. So instead of switching, the
 * selection asks [AtlasWarmGate] to have the server warm that rung from the next segment, and keeps
 * loading the current rung until the gate says the new one is ahead of it. The switch then lands on
 * segments already on disk. Dropping down is never held back.
 *
 * "Current" is the rung of the last segment actually loaded, not the last pick: with HLS a pick
 * first loads the variant's playlist and the selection runs again before any segment is fetched.
 *
 * Already-buffered segments are never thrown away to refetch them higher. A refetch would ask for a
 * segment before where the warm-up started, which restarts that transcode.
 */
@UnstableApi
class AtlasAdaptiveTrackSelection(
  group: TrackGroup,
  tracks: IntArray,
  type: Int,
  bandwidthMeter: BandwidthMeter,
  minDurationForQualityIncreaseMs: Long,
  maxDurationForQualityDecreaseMs: Long,
  minDurationToRetainAfterDiscardMs: Long,
  bandwidthFraction: Float,
  adaptationCheckpoints: List<AdaptationCheckpoint>,
  private val gate: AtlasWarmGate?,
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
  // canSelectFormat also runs inside the super constructor, before these and [gate] are set; they
  // then read as null / defaults ("pick freely"). That pick doesn't stick: the first
  // updateSelectedTrack makes the real initial selection, with [gate] set.
  private var loadedFormat: Format? = null
  private var nextSegment: Long = -1
  private var wantedThisPass = false

  override fun updateSelectedTrack(
    playbackPositionUs: Long,
    bufferedDurationUs: Long,
    availableDurationUs: Long,
    queue: List<MediaChunk>,
    mediaChunkIterators: Array<MediaChunkIterator>,
  ) {
    val last = queue.lastOrNull()
    if (last != null) {
      loadedFormat = last.trackFormat
      // Jellyfin playlists start at media sequence 0, so this is the server's segment index.
      nextSegment = last.chunkIndex + 1
    } else {
      // Seek or reload: nothing loaded at the new position yet, so nothing to warm from.
      nextSegment = -1
    }
    wantedThisPass = false
    super.updateSelectedTrack(playbackPositionUs, bufferedDurationUs, availableDurationUs, queue, mediaChunkIterators)
  }

  override fun canSelectFormat(format: Format, trackBitrate: Int, effectiveBitrate: Long): Boolean {
    val affordable = super.canSelectFormat(format, trackBitrate, effectiveBitrate)
    val gate = gate
    if (gate == null || !gate.isAtlas) return affordable
    val current = loadedFormat
    if (current == null) {
      // First pick of this playback: the lowest rung, whatever the estimate says. It's the one the
      // server started transcoding when it handed out the playlist, so it's the fast start; the
      // estimate (often left over from the last playback) only decides where to warm up next.
      return format.bitrate == lowestBitrate()
    }
    if (format.bitrate <= current.bitrate || !affordable) return affordable
    // An affordable step up. Already warm (or still running from before)? Switch now.
    if (gate.isReady(format)) return true
    // The selection walks from the highest rung down, so the first affordable one is the best this
    // connection can do: that's the one to warm. Rungs in between aren't warm either, so stay put.
    if (!wantedThisPass && nextSegment >= 0) {
      wantedThisPass = true
      gate.want(format, nextSegment)
    }
    return false
  }

  private fun lowestBitrate(): Int {
    var lowest = Int.MAX_VALUE
    for (i in 0 until length()) lowest = minOf(lowest, getFormat(i).bitrate)
    return lowest
  }

  override fun evaluateQueueSize(playbackPositionUs: Long, queue: List<MediaChunk>): Int = queue.size

  /** Builds [AtlasAdaptiveTrackSelection]s with the given tuning. */
  class Factory(
    private val minDurationForQualityIncreaseMs: Long,
    private val maxDurationForQualityDecreaseMs: Long,
    private val minDurationToRetainAfterDiscardMs: Long,
    private val bandwidthFraction: Float,
    private val gate: AtlasWarmGate,
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
    ): AdaptiveTrackSelection = AtlasAdaptiveTrackSelection(
      group,
      tracks,
      type,
      bandwidthMeter,
      minDurationForQualityIncreaseMs,
      maxDurationForQualityDecreaseMs,
      minDurationToRetainAfterDiscardMs,
      bandwidthFraction,
      adaptationCheckpoints,
      gate,
    )
  }
}
