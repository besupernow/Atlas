part of '../../video_player_screen.dart';

extension _VideoPlayerPlaybackPromptMethods on VideoPlayerScreenState {
  void _onVideoCompleted(bool completed, {bool skipAutoPlayCountdown = false}) async {
    if (!completed) return;
    // Live TV streams are continuous — ignore transient EOF events while an
    // HLS playlist refreshes or crosses a discontinuity.
    if (widget.isLive) {
      _logVideoCompleted('live');
      return;
    }
    // Ignore spurious EOF from the old file during an in-place media-source
    // transition (episode swap, transcode restart, channel switch).
    if (_transitionGate.transition != PlaybackTransition.idle) {
      _logVideoCompleted('transition=${_transitionGate.transition.name}');
      return;
    }
    if (_episode.isResolvingCompletionAdjacency) {
      _logVideoCompleted('resolvingAdjacency');
      return;
    }

    // mpv does not flip the `pause` property on EOF, so _onPlayingStateChanged
    // never fires false.  Normalize all playback-dependent state.
    unawaited(_wakelockController.setEnabled(false));
    // A known, positive duration stands in for the EOF position everywhere
    // below — the position stream can stop a beat short of it on EOF.
    final duration = switch (player?.state.duration) {
      final value? when value.inMilliseconds > 0 => value,
      _ => null,
    };
    unawaited(_sendStoppedProgressOnce(positionOverride: duration));
    // The launch receipt is not ended here: the session may go on to the next
    // episode in place, and a receipt marked `completed` now would report the
    // finished item while the next one plays. It reads the live EOF state
    // meanwhile and ends `completed` from _retireLaunchObserver when the
    // screen leaves on this item.
    _mediaControls.pushPlaybackState();
    unawaited(DiscordRPCService.instance.pausePlayback());
    // The item finished, so real-time trackers get a terminal report now rather
    // than whenever the screen happens to tear down: a completion prompt or
    // end-of-video sleep timer can leave it open for minutes, and until then
    // the service would still show the item as playing. Seed the known duration
    // first. A later dispose or in-place reload finds no context and does
    // nothing.
    if (duration != null) {
      TrackerCoordinator.instance.updatePosition(duration);
    }
    unawaited(TrackerCoordinator.instance.stopPlayback());
    if (_autoPipEnabled) {
      unawaited(_updateAutoPipState(isPlaying: false));
    }

    // End-of-video sleep timer takes precedence over autoplay / next-episode
    // dialogs: the user explicitly asked to stop after this item.
    final sleepTimerService = SleepTimerService();
    if (sleepTimerService.isEndOfVideoMode && !_episode.completionLatch.triggered) {
      _logVideoCompleted('sleepTimer');
      _episode.completionLatch.latch();
      sleepTimerService.notifyVideoCompleted();
      return;
    }
    if (!_canNavigateMediaItems()) {
      _logVideoCompleted('cannotNavigate');
      if (!_episode.completionLatch.triggered) _episode.completionLatch.latch();
      return;
    }

    // The early Play Next card (shown over the credits) is already up: let
    // its countdown finish the job. Latch so no second prompt stacks, and
    // stop treating it as early so a paused-at-EOF player doesn't hold it.
    if (_episode.showPlayNextDialog && _episode.playNextEarly) {
      _logVideoCompleted('earlyPromptVisible');
      if (!_episode.completionLatch.triggered) _episode.completionLatch.latch();
      _setPlayerState(() => _episode.playNextEarly = false);
      return;
    }

    var navigationAction = completionNavigationAction(
      hasNext: _episode.next != null,
      adjacentStatus: _episode.nextStatus,
    );
    if (navigationAction == CompletionNavigationAction.retryAdjacent) {
      _logVideoCompleted('action=retryAdjacent');
      _episode.isResolvingCompletionAdjacency = true;
      try {
        await _loadAdjacentEpisodes();
      } finally {
        _episode.isResolvingCompletionAdjacency = false;
      }
      if (!mounted) return;
      navigationAction = completionNavigationAction(
        hasNext: _episode.next != null,
        adjacentStatus: _episode.nextStatus,
      );
      if (navigationAction == CompletionNavigationAction.retryAdjacent) {
        _logVideoCompleted('action=retryAdjacent latched');
        _episode.completionLatch.latch();
        showGlobalErrorSnackBar(t.messages.errorLoadingSeries);
        return;
      }
    }

    if (navigationAction == CompletionNavigationAction.presentNext &&
        !_episode.showPlayNextDialog &&
        !_showStillWatchingPrompt &&
        !_episode.completionLatch.triggered) {
      _episode.completionLatch.latch();

      // The server ended this item's session (a Plex admin stop) and nobody
      // has touched playback since: the buffered item was allowed to finish,
      // but starting the next one on the viewer's behalf is not. The prompt
      // waits for a person instead of counting down.
      final serverStopped = _progressTracker?.stoppedByServer ?? false;

      // PiP: skip dialog (user can't interact), auto-play immediately
      if (PipService().isPipActive.value && !serverStopped) {
        _logVideoCompleted('action=presentNext pip');
        unawaited(_playNext());
        return;
      }

      // Capture keyboard mode before async gap
      final isKeyboardMode = PlatformDetector.isTV() && InputModeTracker.isKeyboardMode(context, listen: false);

      final settings = await SettingsService.getInstance();
      if (!mounted) return;
      final autoPlayEnabled = !serverStopped && settings.read(SettingsService.autoPlayNextEpisode);
      final countdownSeconds = settings.read(SettingsService.playNextCountdown);

      // A zero countdown (#1827) behaves like the PiP path above: no prompt,
      // straight into the next episode.
      if (autoPlayEnabled && (skipAutoPlayCountdown || countdownSeconds == 0)) {
        _logVideoCompleted('action=presentNext autoplay');
        unawaited(_playNext());
        return;
      }

      _logVideoCompleted(serverStopped ? 'action=presentNext prompt serverStopped' : 'action=presentNext prompt');
      _setPlayerState(() {
        _episode.playNextEarly = false;
        _episode.showPlayNextDialog = true;
        _episode.autoPlayCountdown.value = autoPlayEnabled ? countdownSeconds : -1;
      });

      // Auto-focus Play Next button on TV when dialog appears (only in keyboard/TV mode)
      if (isKeyboardMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _playNextConfirmFocusNode.requestFocus();
          }
        });
      }

      if (autoPlayEnabled) {
        _startAutoPlayTimer();
      }
    } else if (navigationAction == CompletionNavigationAction.exit && !_episode.completionLatch.triggered) {
      _logVideoCompleted('action=exit');
      _episode.completionLatch.latch();
      unawaited(_handleBackButton());
    } else {
      _logVideoCompleted('action=${navigationAction.name} latched');
    }
  }

  /// The completion chain used to run silently; one line per accepted EOF
  /// names what the screen decided, for field diagnosis of items that never
  /// advance or exit.
  void _logVideoCompleted(String branch) {
    final state = player?.state;
    appLogger.i(
      'Video completed: $branch '
          '(position=${state?.position.inMilliseconds}ms duration=${state?.duration.inMilliseconds}ms)',
    );
  }

  void _startAutoPlayTimer() {
    if (!_canNavigateMediaItems()) return;
    _episode.autoPlayTimer?.cancel();
    _episode.autoPlayTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      // A backgrounded app on a platform that pauses there has nobody to
      // answer the prompt, and advancing would start the next episode behind
      // the viewer's back; the countdown holds until they return.
      if (_playNextPromptBackgrounded()) return;
      // Early card over the credits: a paused video pauses the countdown
      // too, so pausing to read the credits doesn't skip them anyway.
      if (_episode.playNextEarly && player?.state.playing == false) return;
      final nextCountdown = _episode.autoPlayCountdown.value - 1;
      _episode.autoPlayCountdown.value = nextCountdown;
      if (nextCountdown <= 0) {
        timer.cancel();
        _playNext();
      }
    });
  }

  /// Credits started (or the episode is in its last few seconds with no
  /// credits marker): bring the Play Next card up now with its countdown
  /// running over the end of the episode, instead of waiting for the file to
  /// finish. Returns true when the card is taking over, so the controls drop
  /// their own credits skip button.
  bool _presentPlayNextEarly({required bool fromCredits}) {
    if (!mounted || widget.isLive || !_canNavigateMediaItems()) return false;
    if (_episode.next == null) return false;
    if (_episode.isLoadingNext || _episode.showPlayNextDialog || _showStillWatchingPrompt) return false;
    if (_episode.completionLatch.triggered) return false;
    if (_transitionGate.transition != PlaybackTransition.idle) return false;
    // "Stop after this episode" means the credits play out.
    if (SleepTimerService().isEndOfVideoMode) return false;
    // PiP advances on its own at the end; a server-stopped session waits for
    // a person at the end.
    if (PipService().isPipActive.value) return false;
    if (_progressTracker?.stoppedByServer ?? false) return false;
    final key = _currentMetadata?.globalKey;
    if (key == null || _episode.earlyPromptItemKey == key) return false;
    _episode.earlyPromptItemKey = key;
    unawaited(_showEarlyPlayNextPrompt(fromCredits: fromCredits));
    return true;
  }

  Future<void> _showEarlyPlayNextPrompt({required bool fromCredits}) async {
    final isKeyboardMode = PlatformDetector.isTV() && InputModeTracker.isKeyboardMode(context, listen: false);
    final settings = await SettingsService.getInstance();
    if (!mounted || _episode.isLoadingNext || _episode.showPlayNextDialog || _showStillWatchingPrompt) return;
    if (_episode.next == null || _episode.completionLatch.triggered) return;

    final autoPlayEnabled = settings.read(SettingsService.autoPlayNextEpisode);
    final countdownSeconds = settings.read(SettingsService.playNextCountdown);
    appLogger.i('Play Next shown early (${fromCredits ? 'credits' : 'end of episode'}), autoplay=$autoPlayEnabled');

    // Same as at the end: a zero countdown goes straight to the next episode.
    if (autoPlayEnabled && countdownSeconds == 0) {
      unawaited(_playNext());
      return;
    }

    _setPlayerState(() {
      _episode.showPlayNextDialog = true;
      _episode.playNextEarly = true;
      _episode.playNextEarlyFromCredits = fromCredits;
      _episode.earlyPromptStartMs = player?.state.position.inMilliseconds ?? 0;
      _episode.autoPlayCountdown.value = autoPlayEnabled ? countdownSeconds : -1;
    });

    if (isKeyboardMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playNextConfirmFocusNode.requestFocus();
      });
    }

    if (autoPlayEnabled) _startAutoPlayTimer();
  }

  /// Position tick hook for the early card: shows it in the last few seconds
  /// when nothing (no credits marker) brought it up sooner, and takes it down
  /// when the viewer seeks back out of the end of the episode.
  void _checkEarlyPlayNext(Duration position, Duration duration, {required int countdownSeconds}) {
    final posMs = position.inMilliseconds;
    final durMs = duration.inMilliseconds;
    if (durMs <= 0) return;

    if (_episode.showPlayNextDialog && _episode.playNextEarly) {
      if (posMs < _episode.earlyPromptStartMs - 3000) {
        // Seeked back into the episode: drop the card, and allow it again
        // once they reach the end.
        _cancelAutoPlay();
        _episode.earlyPromptItemKey = null;
      }
      return;
    }

    // Fallback lead: the countdown length, so it reaches zero about as the
    // episode ends. Short items (trailers, extras) don't get it.
    if (countdownSeconds <= 0 || durMs < 10 * 60 * 1000) return;
    final remainingMs = durMs - posMs;
    if (remainingMs > 1500 && remainingMs <= (countdownSeconds + 1) * 1000 && player?.state.playing == true) {
      _presentPlayNextEarly(fromCredits: false);
    }
  }

  /// Whether the Play Next prompt is out of the viewer's sight: the app is in
  /// the background on a platform that pauses playback there
  /// ([shouldPauseVideoForBackground]). PiP stays visible, and its own path
  /// advances without a prompt.
  bool _playNextPromptBackgrounded() {
    if (PipService().isPipActive.value) return false;
    final isAutomotive = PlatformDetector.isAutomotive();
    final state = WidgetsBinding.instance.lifecycleState;
    final backgrounded =
        state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            // A car reports its background transition as inactive (see
            // didChangeAppLifecycleState).
            (isAutomotive && state == AppLifecycleState.inactive);
    return backgrounded &&
        shouldPauseVideoForBackground(
          isHandheld: PlatformDetector.isMobile(context),
          isTv: PlatformDetector.isTV(),
          isAutomotive: isAutomotive,
        );
  }

  /// Re-present the Play Next prompt after an EOF-driven advance failed on a
  /// transient server blip (#1867).
  ///
  /// The failed reload rolled back to the finished episode's last frame, so
  /// without a prompt the screen parks black until the device sleeps — while
  /// a retry seconds later typically succeeds (skipping manually did exactly
  /// that). [playNextRetryPresentation] owns the decision: only EOF-driven
  /// advances that failed with [PlaybackFailureReason.serverUnavailable]
  /// qualify, the auto-play countdown re-fires [_playNext] up to
  /// [maxPlayNextTransientRetries] times, and after that (with auto-play
  /// off, or in a Watch Together session) the prompt waits for a manual
  /// retry.
  void _presentPlayNextRetryPrompt({required bool wasAtCompletion}) async {
    if (!mounted || !_canNavigateMediaItems()) return;
    if (_episode.isLoadingNext || _episode.showPlayNextDialog || _showStillWatchingPrompt) return;

    // Capture keyboard mode before the async gap, same as _onVideoCompleted.
    final isKeyboardMode = PlatformDetector.isTV() && InputModeTracker.isKeyboardMode(context, listen: false);
    final settings = await SettingsService.getInstance();
    if (!mounted || _episode.isLoadingNext || _episode.showPlayNextDialog) return;

    final presentation = playNextRetryPresentation(
      wasAtCompletion: wasAtCompletion,
      failureReason: _episode.lastReloadFailureReason,
      hasNext: _episode.next != null,
      autoPlayEnabled: settings.read(SettingsService.autoPlayNextEpisode),
      inWatchTogetherSession: _watchTogetherRoom() != null,
      autoRetriesUsed: _episode.playNextTransientRetryCount,
    );
    if (presentation == PlayNextRetryPresentation.none) return;

    // The failed reload's rollback reset the latch; re-latch so a duplicate
    // EOF signal from the parked stream cannot stack a second prompt on top.
    if (!_episode.completionLatch.triggered) _episode.completionLatch.latch();

    final countdown = presentation == PlayNextRetryPresentation.countdown;
    if (countdown) _episode.playNextTransientRetryCount++;

    _setPlayerState(() {
      _episode.playNextEarly = false;
      _episode.showPlayNextDialog = true;
      // Deliberately not [SettingsService.playNextCountdown]: this countdown
      // spaces transient-failure retries (see completion_latch.dart), so a
      // user preference of 0 must not collapse it into a hot retry loop.
      _episode.autoPlayCountdown.value = countdown ? 5 : -1;
    });

    if (isKeyboardMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playNextConfirmFocusNode.requestFocus();
      });
    }

    if (countdown) _startAutoPlayTimer();
  }

  /// Put the Play Next prompt back after a reload of the same item cleared it
  /// (TV background suspend restore), resuming its countdown where it held;
  /// a countdown of -1 means auto-play was off and the prompt waits.
  Future<void> _restorePlayNextPrompt({required int countdown}) async {
    if (!mounted || !_canNavigateMediaItems()) return;
    if (_episode.isLoadingNext || _episode.showPlayNextDialog || _showStillWatchingPrompt) return;

    // The restored stream sits at the finished episode's end; its EOF must
    // not raise a second prompt while this one is being put back.
    if (!_episode.completionLatch.triggered) _episode.completionLatch.latch();

    // The reload dropped the adjacent episodes and re-resolves them in the
    // background; the prompt needs its target now.
    if (_episode.next == null) {
      final metadata = _currentMetadata;
      await _loadAdjacentEpisodes(metadata: metadata);
      if (!mounted || _currentMetadata != metadata) return;
    }
    if (_episode.isLoadingNext || _episode.showPlayNextDialog || _showStillWatchingPrompt) return;
    if (_episode.next == null) {
      // Nothing to advance to after all: hand the parked end back to the
      // ordinary completion flow, which retries or exits.
      _episode.completionLatch.reset();
      return;
    }

    final remaining = countdown == 0 ? 1 : countdown;
    _setPlayerState(() {
      _episode.playNextEarly = false;
      _episode.showPlayNextDialog = true;
      _episode.autoPlayCountdown.value = remaining;
    });

    if (PlatformDetector.isTV() && InputModeTracker.isKeyboardMode(context, listen: false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playNextConfirmFocusNode.requestFocus();
      });
    }

    if (remaining > 0) _startAutoPlayTimer();
  }

  void _cancelAutoPlay() {
    if (_shuttingDown) return;
    _episode.autoPlayTimer?.cancel();
    _unfocusPlayNextPrompt();
    // The early card comes up while the episode is still playing and
    // reporting; there's no stopped report to undo.
    if (!_episode.playNextEarly) _progressTracker?.resumeAfterStoppedReport();
    // Keep the latch set while playback is still parked at EOF, so duplicate
    // completed signals cannot re-open this prompt. It is re-armed once playback
    // seeks back clear of the end region (see the position listener) or new media loads.
    _setPlayerState(() {
      _episode.showPlayNextDialog = false;
      _episode.playNextEarly = false;
    });
  }

  void _dismissPlaybackPromptForBack() {
    if (_episode.showPlayNextDialog) {
      _cancelAutoPlay();
      return;
    }
    if (_showStillWatchingPrompt) {
      _dismissStillWatching();
    }
  }

  /// Re-arm the end-of-video latch so Play Next can fire again. Callers
  /// decide *when* it is safe to re-arm (media reloaded, or playback moved
  /// back out of the end region); the latch itself refuses while a prompt
  /// or countdown is active.
  void _rearmCompletionLatch() {
    _episode.completionLatch.rearmIfClear(
      promptVisible: _episode.showPlayNextDialog,
      countdownActive: _episode.autoPlayTimer?.isActive == true,
    );
  }

  void _showStillWatchingDialog() {
    // Don't show if auto-play dialog is already visible
    if (_episode.showPlayNextDialog) return;

    final isKeyboardMode = PlatformDetector.isTV() && InputModeTracker.isKeyboardMode(context, listen: false);

    _setPlayerState(() {
      _showStillWatchingPrompt = true;
      _stillWatchingCountdown.value = 30;
    });

    if (isKeyboardMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _stillWatchingContinueFocusNode.requestFocus();
      });
    }

    _stillWatchingTimer?.cancel();
    _stillWatchingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final nextCountdown = _stillWatchingCountdown.value - 1;
      _stillWatchingCountdown.value = nextCountdown;
      if (nextCountdown <= 0) {
        timer.cancel();
        _onStillWatchingTimeout();
      }
    });
  }

  void _onStillWatchingTimeout() {
    _unfocusStillWatchingPrompt();
    final currentPlayer = player;
    if (currentPlayer != null) {
      _dispatchPlaybackIntent(_pauseWithPlaybackIntent(currentPlayer), source: 'Still watching');
    }
    _setPlayerState(() {
      _showStillWatchingPrompt = false;
    });
  }

  void _onStillWatchingContinue() {
    _stillWatchingTimer?.cancel();
    _unfocusStillWatchingPrompt();
    SleepTimerService().restartTimer();
    _setPlayerState(() {
      _showStillWatchingPrompt = false;
    });
  }

  void _onStillWatchingPause() {
    _stillWatchingTimer?.cancel();
    _unfocusStillWatchingPrompt();
    final currentPlayer = player;
    if (currentPlayer != null) {
      _dispatchPlaybackIntent(_pauseWithPlaybackIntent(currentPlayer), source: 'Still watching');
    }
    _setPlayerState(() {
      _showStillWatchingPrompt = false;
    });
  }

  void _dismissStillWatching() {
    _stillWatchingTimer?.cancel();
    if (_showStillWatchingPrompt) {
      _unfocusStillWatchingPrompt();
      // Back or a next-episode action on the visible prompt is the same
      // "still watching" acknowledgement as Continue: re-arm the sleep timer.
      // Guarded on prompt visibility — ordinary navigation also dismisses
      // here and must leave an armed timer untouched.
      SleepTimerService().restartTimer();
      _setPlayerState(() {
        _showStillWatchingPrompt = false;
      });
    }
  }

  void _unfocusPlayNextPrompt() {
    _playNextCancelFocusNode.unfocus();
    _playNextConfirmFocusNode.unfocus();
  }

  void _unfocusStillWatchingPrompt() {
    _stillWatchingPauseFocusNode.unfocus();
    _stillWatchingContinueFocusNode.unfocus();
  }
}
