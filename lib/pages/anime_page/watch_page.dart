import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import './select_source.dart';
import '../../components/player/player.dart';
import '../../config.dart';
import '../../core/extractor/animes/model.dart' as anime_model;
import '../../core/extractor/extractors.dart' as extractor;
import '../../core/models/player.dart' as player_model;
import '../../core/models/tracker_provider.dart';
import '../../core/trackers/providers.dart';
import '../../plugins/helpers/screen.dart';
import '../../plugins/helpers/ui.dart';
import '../../plugins/helpers/utils/duration.dart';
import '../../plugins/helpers/utils/list.dart';
import '../../plugins/state.dart' show AppState;
import '../../plugins/translator/translator.dart';
import '../settings_page/setting_dialog.dart';
import '../settings_page/setting_radio.dart';
import '../settings_page/setting_switch.dart';
import '../settings_page/setting_tile.dart';

class VideoDuration {
  VideoDuration(this.current, this.total);

  final Duration current;
  final Duration total;
}

class WatchPage extends StatefulWidget {
  const WatchPage({
    required final this.title,
    required final this.episode,
    required final this.plugin,
    required final this.totalEpisodes,
    required final this.onPop,
    required final this.previousEpisodeEnabled,
    required final this.previousEpisode,
    required final this.nextEpisodeEnabled,
    required final this.nextEpisode,
    required final this.ignoreAutoFullscreen,
    required final this.onIgnoreAutoFullscreenChange,
    final Key? key,
  }) : super(key: key);

  final String title;
  final anime_model.EpisodeInfo episode;
  final String plugin;
  final int totalEpisodes;
  final void Function() onPop;
  final bool previousEpisodeEnabled;
  final void Function() previousEpisode;
  final bool nextEpisodeEnabled;
  final void Function() nextEpisode;
  final bool ignoreAutoFullscreen;
  final void Function(bool ignoreAutoFullscreen) onIgnoreAutoFullscreenChange;

  @override
  WatchPageState createState() => WatchPageState();
}

class WatchPageState extends State<WatchPage>
    with TickerProviderStateMixin, FullscreenMixin {
  List<anime_model.EpisodeSource>? sources;
  int? currentIndex;
  player_model.Player? player;
  Widget? playerChild;

  bool showControls = true;
  bool locked = false;
  bool autoPlay = AppState.settings.current.autoPlay;
  bool autoNext = AppState.settings.current.autoNext;
  bool? wasPausedBySlider;
  double speed = player_model.Player.defaultSpeed;
  int seekDuration = AppState.settings.current.seekDuration;
  int introDuration = AppState.settings.current.introDuration;
  final Duration animationDuration = const Duration(milliseconds: 300);

  final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false);
  late AnimationController playPauseController;
  late AnimationController overlayController;

  late final ValueNotifier<VideoDuration> duration =
      ValueNotifier<VideoDuration>(
    VideoDuration(Duration.zero, Duration.zero),
  );
  late final ValueNotifier<int> volume = ValueNotifier<int>(
    100,
  );

  final Widget loader = const Center(
    child: CircularProgressIndicator(),
  );

  Timer? _mouseOverlayTimer;
  bool hasSynced = false;
  bool ignoreExitFullscreen = false;

  @override
  void initState() {
    super.initState();

    initFullscreen();

    Future<void>.delayed(Duration.zero, () async {
      if (AppState.settings.current.animeAutoFullscreen &&
          !widget.ignoreAutoFullscreen) {
        enterFullscreen();
      }

      getSources();
    });

    playPauseController = AnimationController(
      vsync: this,
      duration: animationDuration,
    );

    overlayController = AnimationController(
      vsync: this,
      duration: animationDuration,
      value: showControls ? 1 : 0,
    );

    overlayController.addStatusListener((final AnimationStatus status) {
      switch (status) {
        case AnimationStatus.forward:
          setState(() {
            showControls = true;
          });
          break;

        case AnimationStatus.dismissed:
          setState(() {
            showControls = overlayController.isCompleted;
          });
          break;

        default:
          setState(() {
            showControls = overlayController.value > 0;
          });
          break;
      }
    });

    _updateLandscape();
  }

  @override
  void dispose() {
    if (!ignoreExitFullscreen) {
      exitFullscreen();
    }

    playerChild = null;
    player?.destroy();

    isPlaying.dispose();
    duration.dispose();
    volume.dispose();
    playPauseController.dispose();
    overlayController.dispose();
    _mouseOverlayTimer?.cancel();

    _updateLandscape(true);

    super.dispose();
  }

  Future<void> getSources() async {
    sources = await extractor.Extractors.anime[widget.plugin]!
        .getSources(widget.episode);

    if (mounted) {
      setState(() {});

      if (sources!.isNotEmpty) {
        await showSelectSources();
      }
    }
  }

  Future<void> setPlayer(final int index) async {
    setState(() {
      currentIndex = index;
      playerChild = null;
    });

    if (player != null) {
      player!.destroy();
    }

    isPlaying.value = false;

    player = createPlayer(
      player_model.PlayerSource(
        url: sources![currentIndex!].url,
        headers: sources![currentIndex!].headers,
      ),
    )..subscribe(_subscriber);

    await player!.load();
  }

  void _subscriber(final player_model.PlayerEvents event) {
    switch (event) {
      case player_model.PlayerEvents.load:
        player!.setVolume(volume.value);
        setState(() {
          playerChild = player!.getWidget();
        });
        _updateDuration();
        if (autoPlay) {
          player!.play();
        }
        break;

      case player_model.PlayerEvents.durationUpdate:
        _updateDuration();
        break;

      case player_model.PlayerEvents.play:
        isPlaying.value = true;
        break;

      case player_model.PlayerEvents.pause:
        isPlaying.value = false;
        break;

      case player_model.PlayerEvents.seek:
        if (wasPausedBySlider == true) {
          player!.play();
          wasPausedBySlider = null;
        }
        break;

      case player_model.PlayerEvents.volume:
        volume.value = player!.volume;
        break;

      case player_model.PlayerEvents.end:
        if (autoNext) {
          if (widget.nextEpisodeEnabled) {
            ignoreExitFullscreen = true;
            widget.nextEpisode();
          }
        }
        break;

      case player_model.PlayerEvents.speed:
        speed = player!.speed;
        break;
    }
  }

  Future<void> _updateDuration() async {
    duration.value = VideoDuration(
      player?.duration ?? Duration.zero,
      player?.totalDuration ?? Duration.zero,
    );

    if ((duration.value.current.inSeconds / duration.value.total.inSeconds) *
            100 >
        AppState.settings.current.animeTrackerWatchPercent) {
      final int? episode = int.tryParse(widget.episode.episode);

      if (episode != null && !hasSynced) {
        hasSynced = true;

        final AnimeProgress progress = AnimeProgress(episodes: episode);

        for (final TrackerProvider<AnimeProgress, dynamic> provider
            in animeProviders) {
          if (provider.isEnabled(widget.title, widget.plugin)) {
            final ResolvedTrackerItem<dynamic>? item =
                await provider.getComputed(widget.title, widget.plugin);

            if (item != null) {
              await provider.updateComputed(
                item,
                progress,
              );
            }
          }
        }
      }
    }
  }

  void _updateLandscape([final bool reset = false]) {
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setPreferredOrientations(
        !reset && AppState.settings.current.fullscreenVideoPlayer
            ? <DeviceOrientation>[
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : <DeviceOrientation>[],
      );
    }
  }

  Future<void> showSelectSources() async {
    final dynamic value = await showGeneralDialog(
      context: context,
      barrierDismissible: currentIndex != null,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      pageBuilder: (
        final BuildContext context,
        final Animation<double> a1,
        final Animation<double> a2,
      ) =>
          SelectSourceWidget(
        sources: sources!,
        selected: currentIndex != null ? sources![currentIndex!] : null,
      ),
    );

    if (value is anime_model.EpisodeSource) {
      final int index = sources!.indexOf(value);
      if (index >= 0) {
        setPlayer(index);
      }
    } else if (currentIndex == null) {
      widget.onPop();
    }
  }

  void showOptions() {
    showModalBottomSheet(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(remToPx(0.5)),
          topRight: Radius.circular(remToPx(0.5)),
        ),
      ),
      context: context,
      builder: (final BuildContext context) => StatefulBuilder(
        builder: (
          final BuildContext context,
          final StateSetter setState,
        ) =>
            Padding(
          padding: EdgeInsets.symmetric(vertical: remToPx(0.25)),
          child: SingleChildScrollView(
            child: Wrap(
              children: <Widget>[
                Column(
                  children: <Widget>[
                    SettingSwitch(
                      title: Translator.t.landscapeVideoPlayer(),
                      icon: Icons.screen_lock_landscape,
                      desc: Translator.t.landscapeVideoPlayerDetail(),
                      value: AppState.settings.current.fullscreenVideoPlayer,
                      onChanged: (final bool val) async {
                        AppState.settings.current.fullscreenVideoPlayer = val;
                        await AppState.settings.current.save();
                        _updateLandscape();
                        setState(() {});
                      },
                    ),
                    ValueListenableBuilder<int>(
                      valueListenable: volume,
                      builder: (
                        final BuildContext context,
                        int volume,
                        final Widget? child,
                      ) =>
                          SettingTile(
                        icon: Icons.volume_up,
                        title: Translator.t.volume(),
                        subtitle: '$volume%',
                        onTap: () async {
                          await showGeneralDialog(
                            context: context,
                            barrierDismissible: true,
                            barrierLabel: MaterialLocalizations.of(context)
                                .modalBarrierDismissLabel,
                            pageBuilder: (
                              final BuildContext context,
                              final Animation<double> a1,
                              final Animation<double> a2,
                            ) =>
                                StatefulBuilder(
                              builder: (
                                final BuildContext context,
                                final StateSetter setState,
                              ) =>
                                  Dialog(
                                child: Row(
                                  children: <Widget>[
                                    IconButton(
                                      icon: const Icon(Icons.volume_mute),
                                      onPressed: () {
                                        player?.setVolume(
                                          player_model.Player.minVolume,
                                        );
                                        volume = player_model.Player.minVolume;
                                        setState(() {});
                                      },
                                    ),
                                    Expanded(
                                      child: Wrap(
                                        children: <Widget>[
                                          SliderTheme(
                                            data: SliderThemeData(
                                              thumbShape: RoundSliderThumbShape(
                                                enabledThumbRadius:
                                                    remToPx(0.4),
                                              ),
                                              showValueIndicator:
                                                  ShowValueIndicator.always,
                                            ),
                                            child: Slider(
                                              label: '$volume%',
                                              value: volume.toDouble(),
                                              min: player_model.Player.minVolume
                                                  .toDouble(),
                                              max: player_model.Player.maxVolume
                                                  .toDouble(),
                                              onChanged: (final double value) {
                                                volume = value.toInt();
                                                setState(() {});
                                              },
                                              onChangeEnd:
                                                  (final double value) {
                                                player?.setVolume(
                                                  value.toInt(),
                                                );
                                                setState(() {});
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.volume_up),
                                      onPressed: () {
                                        player?.setVolume(
                                          player_model.Player.maxVolume,
                                        );
                                        volume = player_model.Player.maxVolume;
                                        setState(() {});
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    SettingRadio<double>(
                      title: Translator.t.speed(),
                      icon: Icons.speed,
                      value: speed,
                      labels: <double, String>{
                        for (final double speed
                            in player_model.Player.allowedSpeeds)
                          speed: '${speed}x',
                      },
                      onChanged: (final double val) async {
                        await player?.setSpeed(val);
                        setState(() {
                          speed = val;
                        });
                      },
                    ),
                    SettingDialog(
                      title: Translator.t.skipIntroDuration(),
                      icon: Icons.fast_forward,
                      subtitle: '$introDuration ${Translator.t.seconds()}',
                      builder: (
                        final BuildContext context,
                        final StateSetter setState,
                      ) =>
                          Wrap(
                        children: <Widget>[
                          SliderTheme(
                            data: SliderThemeData(
                              thumbShape: RoundSliderThumbShape(
                                enabledThumbRadius: remToPx(0.4),
                              ),
                              showValueIndicator: ShowValueIndicator.always,
                            ),
                            child: Slider(
                              label: '$introDuration ${Translator.t.seconds()}',
                              value: introDuration.toDouble(),
                              min:
                                  player_model.Player.minIntroLength.toDouble(),
                              max:
                                  player_model.Player.maxIntroLength.toDouble(),
                              onChanged: (final double value) {
                                setState(() {
                                  introDuration = value.toInt();
                                });
                              },
                              onChangeEnd: (final double value) async {
                                setState(() {
                                  introDuration = value.toInt();
                                });
                                AppState.settings.current.introDuration =
                                    introDuration;
                                await AppState.settings.current.save();
                                this.setState(() {});
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    SettingDialog(
                      title: Translator.t.seekDuration(),
                      icon: Icons.fast_forward,
                      subtitle: '$seekDuration ${Translator.t.seconds()}',
                      builder: (
                        final BuildContext context,
                        final StateSetter setState,
                      ) =>
                          Wrap(
                        children: <Widget>[
                          SliderTheme(
                            data: SliderThemeData(
                              thumbShape: RoundSliderThumbShape(
                                enabledThumbRadius: remToPx(0.4),
                              ),
                              showValueIndicator: ShowValueIndicator.always,
                            ),
                            child: Slider(
                              label: '$seekDuration ${Translator.t.seconds()}',
                              value: seekDuration.toDouble(),
                              min: player_model.Player.minSeekLength.toDouble(),
                              max: player_model.Player.maxSeekLength.toDouble(),
                              onChanged: (final double value) {
                                setState(() {
                                  seekDuration = value.toInt();
                                });
                              },
                              onChangeEnd: (final double value) async {
                                setState(() {
                                  seekDuration = value.toInt();
                                });
                                AppState.settings.current.seekDuration =
                                    seekDuration;
                                await AppState.settings.current.save();
                                this.setState(() {});
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    SettingSwitch(
                      title: Translator.t.autoPlay(),
                      icon: Icons.slideshow,
                      desc: Translator.t.autoPlayDetail(),
                      value: autoPlay,
                      onChanged: (final bool val) async {
                        setState(() {
                          autoPlay = val;
                        });
                        AppState.settings.current.autoPlay = val;
                        await AppState.settings.current.save();
                      },
                    ),
                    SettingSwitch(
                      title: Translator.t.autoNext(),
                      icon: Icons.skip_next,
                      desc: Translator.t.autoNextDetail(),
                      value: AppState.settings.current.autoNext,
                      onChanged: (final bool val) async {
                        setState(() {
                          autoNext = val;
                        });
                        AppState.settings.current.autoNext = val;
                        await AppState.settings.current.save();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget actionButton({
    required final IconData icon,
    required final String label,
    required final void Function() onPressed,
    required final bool enabled,
  }) =>
      OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.symmetric(
            horizontal: remToPx(0.2),
          ),
          side: BorderSide(
            color: Colors.white.withOpacity(0.3),
          ),
          backgroundColor: Colors.black.withOpacity(0.5),
        ),
        onPressed: enabled ? onPressed : null,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: remToPx(0.4),
            vertical: remToPx(0.2),
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  icon,
                  size: Theme.of(context).textTheme.subtitle1?.fontSize,
                  color: Colors.white,
                ),
                SizedBox(
                  width: remToPx(0.2),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: Theme.of(context).textTheme.subtitle1?.fontSize,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget getLayoutedButton(
    final BuildContext context,
    final List<Widget> children,
    final int maxPerWhenSm,
  ) {
    final double width = MediaQuery.of(context).size.width;
    final Widget spacer = SizedBox(
      width: remToPx(0.4),
    );

    if (width < ResponsiveSizes.sm) {
      final List<List<Widget>> rows = ListUtils.chunk(children, maxPerWhenSm);

      return Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: rows
            .map(
              (final List<Widget> x) => Flexible(
                child: Row(
                  children: ListUtils.insertBetween(x, spacer),
                ),
              ),
            )
            .toList(),
      );
    }

    return Row(
      children: ListUtils.insertBetween(children, spacer),
    );
  }

  void _updateMouseOverlay() {
    if (!showControls) {
      overlayController.forward();
    }

    _mouseOverlayTimer?.cancel();
    _mouseOverlayTimer = Timer(MiscSettings.mouseOverlayDuration, () {
      overlayController.reverse();
    });
  }

  @override
  Widget build(final BuildContext context) {
    final Widget lock = IconButton(
      onPressed: () {
        setState(() {
          locked = !locked;
        });
      },
      icon: Icon(
        locked ? Icons.lock : Icons.lock_open,
      ),
      color: Colors.white,
    );

    final Widget fullscreenBtn = ValueListenableBuilder<bool>(
      valueListenable: isFullscreened,
      builder: (
        final BuildContext builder,
        final bool isFullscreened,
        final Widget? child,
      ) =>
          IconButton(
        color: Colors.white,
        onPressed: () {
          if (isFullscreened) {
            widget.onIgnoreAutoFullscreenChange(true);
            exitFullscreen();
          } else {
            widget.onIgnoreAutoFullscreenChange(false);
            enterFullscreen();
          }
        },
        icon: Icon(
          isFullscreened ? Icons.fullscreen_exit : Icons.fullscreen,
        ),
      ),
    );

    // Material(
    //                             type: MaterialType.transparency,
    //                             child: Center(
    //                               child: Text(
    //                                 Translator.t.noValidSources(),
    //                               ),
    //                             ),
    //                           )

    return Material(
      type: MaterialType.transparency,
      child: MouseRegion(
        onEnter: (final PointerEnterEvent event) {
          _updateMouseOverlay();
        },
        onHover: (final PointerHoverEvent event) {
          _updateMouseOverlay();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _updateMouseOverlay();
          },
          child: Stack(
            children: <Widget>[
              if (playerChild != null)
                playerChild!
              else if (sources?.isEmpty ?? false)
                Center(
                  child: Text(
                    Translator.t.noValidSources(),
                    style: TextStyle(
                      fontSize: Theme.of(context).textTheme.subtitle1?.fontSize,
                      color: Colors.white,
                    ),
                  ),
                )
              else
                loader,
              FadeTransition(
                opacity: overlayController,
                child: showControls
                    ? Container(
                        color: !locked
                            ? Colors.black.withOpacity(0.3)
                            : Colors.transparent,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: remToPx(0.7),
                          ),
                          child: Stack(
                            children: locked
                                ? <Widget>[
                                    Align(
                                      alignment: Alignment.topRight,
                                      child: Padding(
                                        padding: EdgeInsets.only(
                                          top: remToPx(0.5),
                                        ),
                                        child: lock,
                                      ),
                                    ),
                                  ]
                                : <Widget>[
                                    Align(
                                      alignment: Alignment.topCenter,
                                      child: Padding(
                                        padding: EdgeInsets.only(
                                          top: remToPx(0.5),
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            IconButton(
                                              icon:
                                                  const Icon(Icons.arrow_back),
                                              onPressed: widget.onPop,
                                              padding: EdgeInsets.only(
                                                right: remToPx(1),
                                                top: remToPx(0.5),
                                                bottom: remToPx(0.5),
                                              ),
                                              color: Colors.white,
                                            ),
                                            Flexible(
                                              fit: FlexFit.tight,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: <Widget>[
                                                  Text(
                                                    widget.title,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize:
                                                          Theme.of(context)
                                                              .textTheme
                                                              .headline6
                                                              ?.fontSize,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                  Text(
                                                    '${Translator.t.episode()} ${widget.episode.episode} of ${widget.totalEpisodes}',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            lock,
                                            IconButton(
                                              onPressed: () {
                                                showOptions();
                                              },
                                              icon: const Icon(Icons.more_vert),
                                              color: Colors.white,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    Align(
                                      child: playerChild != null
                                          ? Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.spaceAround,
                                              children: <Widget>[
                                                Material(
                                                  type:
                                                      MaterialType.transparency,
                                                  shape: const CircleBorder(),
                                                  clipBehavior: Clip.hardEdge,
                                                  child: IconButton(
                                                    iconSize: remToPx(2),
                                                    onPressed: () {
                                                      if (player?.ready ??
                                                          false) {
                                                        final Duration amt =
                                                            duration.value
                                                                    .current -
                                                                Duration(
                                                                  seconds:
                                                                      seekDuration,
                                                                );
                                                        player!.seek(
                                                          amt <= Duration.zero
                                                              ? Duration.zero
                                                              : amt,
                                                        );
                                                      }
                                                    },
                                                    icon: const Icon(
                                                      Icons.fast_rewind,
                                                    ),
                                                    color: Colors.white,
                                                  ),
                                                ),
                                                ValueListenableBuilder<bool>(
                                                  valueListenable: isPlaying,
                                                  builder: (
                                                    final BuildContext context,
                                                    final bool isPlaying,
                                                    final Widget? child,
                                                  ) {
                                                    isPlaying
                                                        ? playPauseController
                                                            .forward()
                                                        : playPauseController
                                                            .reverse();
                                                    return Material(
                                                      type: MaterialType
                                                          .transparency,
                                                      shape:
                                                          const CircleBorder(),
                                                      clipBehavior:
                                                          Clip.hardEdge,
                                                      child: IconButton(
                                                        iconSize: remToPx(3),
                                                        onPressed: () {
                                                          if (player != null &&
                                                              player!.ready) {
                                                            isPlaying
                                                                ? player!
                                                                    .pause()
                                                                : player!
                                                                    .play();
                                                          }
                                                        },
                                                        icon: AnimatedIcon(
                                                          icon: AnimatedIcons
                                                              .play_pause,
                                                          progress:
                                                              playPauseController,
                                                        ),
                                                        color: Colors.white,
                                                      ),
                                                    );
                                                  },
                                                ),
                                                Material(
                                                  type:
                                                      MaterialType.transparency,
                                                  shape: const CircleBorder(),
                                                  clipBehavior: Clip.hardEdge,
                                                  child: IconButton(
                                                    iconSize: remToPx(2),
                                                    onPressed: () {
                                                      if (player?.ready ??
                                                          false) {
                                                        final Duration amt =
                                                            duration.value
                                                                    .current +
                                                                Duration(
                                                                  seconds:
                                                                      seekDuration,
                                                                );
                                                        player!.seek(
                                                          amt <
                                                                  duration.value
                                                                      .total
                                                              ? amt
                                                              : duration
                                                                  .value.total,
                                                        );
                                                      }
                                                    },
                                                    icon: const Icon(
                                                      Icons.fast_forward,
                                                    ),
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ],
                                            )
                                          : const SizedBox.shrink(),
                                    ),
                                    Align(
                                      alignment: Alignment.bottomCenter,
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: <Widget>[
                                          Flexible(
                                            child: getLayoutedButton(
                                              context,
                                              <Widget>[
                                                Expanded(
                                                  child: actionButton(
                                                    icon: Icons.skip_previous,
                                                    label:
                                                        Translator.t.previous(),
                                                    onPressed: () {
                                                      ignoreExitFullscreen =
                                                          true;
                                                      widget.previousEpisode();
                                                    },
                                                    enabled: widget
                                                        .previousEpisodeEnabled,
                                                  ),
                                                ),
                                                Expanded(
                                                  child: actionButton(
                                                    icon: Icons.fast_forward,
                                                    label: Translator.t
                                                        .skipIntro(),
                                                    onPressed: () {
                                                      if (player?.ready ??
                                                          false) {
                                                        final Duration amt =
                                                            duration.value
                                                                    .current +
                                                                Duration(
                                                                  seconds:
                                                                      introDuration,
                                                                );
                                                        player!.seek(
                                                          amt <
                                                                  duration.value
                                                                      .total
                                                              ? amt
                                                              : duration
                                                                  .value.total,
                                                        );
                                                      }
                                                    },
                                                    enabled:
                                                        playerChild != null,
                                                  ),
                                                ),
                                                Expanded(
                                                  child: actionButton(
                                                    icon: Icons.playlist_play,
                                                    label:
                                                        Translator.t.sources(),
                                                    onPressed:
                                                        showSelectSources,
                                                    enabled:
                                                        sources?.isNotEmpty ??
                                                            false,
                                                  ),
                                                ),
                                                Expanded(
                                                  child: actionButton(
                                                    icon: Icons.skip_next,
                                                    label: Translator.t.next(),
                                                    onPressed: () {
                                                      ignoreExitFullscreen =
                                                          true;
                                                      widget.nextEpisode();
                                                    },
                                                    enabled: widget
                                                        .nextEpisodeEnabled,
                                                  ),
                                                ),
                                                if (playerChild == null)
                                                  fullscreenBtn,
                                              ],
                                              2,
                                            ),
                                          ),
                                          if (playerChild == null)
                                            SizedBox(
                                              height: remToPx(0.5),
                                            )
                                          else
                                            ValueListenableBuilder<
                                                VideoDuration>(
                                              valueListenable: duration,
                                              builder: (
                                                final BuildContext context,
                                                final VideoDuration duration,
                                                final Widget? child,
                                              ) =>
                                                  Row(
                                                children: <Widget>[
                                                  Container(
                                                    constraints: BoxConstraints(
                                                      minWidth: remToPx(1.8),
                                                    ),
                                                    child: Text(
                                                      DurationUtils.pretty(
                                                        duration.current,
                                                      ),
                                                      textAlign:
                                                          TextAlign.center,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                  Expanded(
                                                    child: SliderTheme(
                                                      data: SliderThemeData(
                                                        thumbShape:
                                                            RoundSliderThumbShape(
                                                          enabledThumbRadius:
                                                              remToPx(0.3),
                                                        ),
                                                        showValueIndicator:
                                                            ShowValueIndicator
                                                                .always,
                                                      ),
                                                      child: Slider(
                                                        label: DurationUtils
                                                            .pretty(
                                                          duration.current,
                                                        ),
                                                        value: duration
                                                            .current.inSeconds
                                                            .toDouble(),
                                                        max: duration
                                                            .total.inSeconds
                                                            .toDouble(),
                                                        onChanged: (
                                                          final double value,
                                                        ) {
                                                          this.duration.value =
                                                              VideoDuration(
                                                            Duration(
                                                              seconds:
                                                                  value.toInt(),
                                                            ),
                                                            duration.total,
                                                          );
                                                        },
                                                        onChangeStart: (
                                                          final double value,
                                                        ) {
                                                          if (player
                                                                  ?.isPlaying ??
                                                              false) {
                                                            player!.pause();
                                                            wasPausedBySlider =
                                                                true;
                                                          }
                                                        },
                                                        onChangeEnd: (
                                                          final double value,
                                                        ) async {
                                                          if (player?.ready ??
                                                              false) {
                                                            await player!.seek(
                                                              Duration(
                                                                seconds: value
                                                                    .toInt(),
                                                              ),
                                                            );
                                                          }
                                                        },
                                                      ),
                                                    ),
                                                  ),
                                                  ConstrainedBox(
                                                    constraints: BoxConstraints(
                                                      minWidth: remToPx(1.8),
                                                    ),
                                                    child: Text(
                                                      DurationUtils.pretty(
                                                        duration.total,
                                                      ),
                                                      textAlign:
                                                          TextAlign.center,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                  fullscreenBtn,
                                                ],
                                              ),
                                            )
                                        ],
                                      ),
                                    ),
                                  ],
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}