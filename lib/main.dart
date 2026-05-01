import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:zakat_radio_app/admin_dashboard.dart';
import 'package:audio_session/audio_session.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const MethodChannel _nativeChannel = MethodChannel(
  'ly.zakatfund.radioapp/native',
);
const String _waslPackageName = 'ly.gov.zakatfund.wasl';
const String _waslStoreUrl =
    'https://play.google.com/store/apps/details?id=$_waslPackageName';
const String _waslFallbackUrl = 'https://www.facebook.com/wasl.zakatlibya';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await JustAudioBackground.init(
    androidNotificationChannelId: 'ly.zakat.radio.audio',
    androidNotificationChannelName: 'إذاعة صندوق الزكاة الليبي',
    androidNotificationOngoing: true,
  );
  runApp(const MyApp());
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

double _scaleFor(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return math
      .min(size.width / 390, size.height / 760)
      .clamp(0.78, 1.0)
      .toDouble();
}

bool _isTelevisionLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width >= 900 && size.width > size.height;
}

enum _MotionQuality { full, balanced, saver }

enum _TvExitAction { keep, stop, cancel }

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(brightness: Brightness.dark);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'إذاعة صندوق الزكاة الليبي',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD5C09C),
          brightness: Brightness.dark,
        ),
        textTheme: GoogleFonts.tajawalTextTheme(baseTheme.textTheme),
        useMaterial3: true,
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: RadioPage(),
      ),
    );
  }
}

class RadioPage extends StatefulWidget {
  const RadioPage({super.key});

  @override
  State<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends State<RadioPage> with WidgetsBindingObserver {
  final AudioPlayer _player = AudioPlayer();
  final String _streamUrl =
      'https://radio.zakatfund.gov.ly/listen/zakat/radio.mp3';

  bool _isBusy = false;
  bool _userWantsPlayback = false;
  bool _wasPlayingBeforeInterruption = false;
  bool _isStreamLoaded = false;
  bool _isPreparingStream = false;
  bool _isRecoveringPlayback = false;
  bool _isTvExitDialogOpen = false;
  bool _autoPlayOnLaunch = false;
  _MotionQuality _motionQuality = _MotionQuality.balanced;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  Timer? _sleepTimer;
  Timer? _sleepTicker;
  Duration? _sleepDuration;
  Duration? _sleepRemaining;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _playingSubscription = _player.playingStream.listen((isPlaying) {
      if (isPlaying && !_userWantsPlayback) {
        _userWantsPlayback = true;
        unawaited(_ensureStreamReady().catchError((_) {}));
      }
    });
    unawaited(_configureAudioSession());
    unawaited(_configureNotifications());
    unawaited(_loadUserSettings());
  }

  bool get _animateBackground =>
      _motionQuality == _MotionQuality.full ||
      (!Platform.isAndroid && _motionQuality == _MotionQuality.balanced);

  bool get _animateHero =>
      _motionQuality == _MotionQuality.full ||
      (!Platform.isAndroid && _motionQuality == _MotionQuality.balanced);

  bool get _animateLivePill =>
      _motionQuality == _MotionQuality.full ||
      (!Platform.isAndroid && _motionQuality == _MotionQuality.balanced);

  bool get _animateWaves => _motionQuality != _MotionQuality.saver;

  Future<void> _loadUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMotion = prefs.getString('motion_quality');
    final motionQuality = _MotionQuality.values.firstWhere(
      (quality) => quality.name == savedMotion,
      orElse: () => _MotionQuality.balanced,
    );

    if (!mounted) return;
    setState(() {
      _motionQuality = motionQuality;
      _autoPlayOnLaunch = prefs.getBool('auto_play_on_launch') ?? false;
    });

    if (_autoPlayOnLaunch) {
      unawaited(_startPlayback());
    }
  }

  Future<void> _saveMotionQuality(_MotionQuality quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('motion_quality', quality.name);
    if (mounted) setState(() => _motionQuality = quality);
  }

  Future<void> _saveAutoPlay(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_play_on_launch', value);
    if (mounted) setState(() => _autoPlayOnLaunch = value);
  }

  Future<void> _configureNotifications() async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      await messaging.subscribeToTopic('all');
    } catch (_) {}
  }

  Future<void> _configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _interruptionSubscription = session.interruptionEventStream.listen((event) {
      if (event.begin) {
        _wasPlayingBeforeInterruption = _userWantsPlayback;
        return;
      }

      if (_wasPlayingBeforeInterruption) {
        if (_lifecycleState == AppLifecycleState.resumed) {
          unawaited(_recoverPlayback(session));
        } else {
          unawaited(_ensureStreamReady().catchError((_) {}));
        }
      }
      _wasPlayingBeforeInterruption = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed && _userWantsPlayback) {
      unawaited(_recoverPlayback());
    }
  }

  Future<void> _recoverPlayback([AudioSession? session]) async {
    if (_isRecoveringPlayback || !_userWantsPlayback) return;

    _isRecoveringPlayback = true;
    try {
      session ??= await AudioSession.instance;
      await session.setActive(true);

      for (var attempt = 0; attempt < 2 && _userWantsPlayback; attempt++) {
        await Future<void>.delayed(
          Duration(milliseconds: 450 + (attempt * 450)),
        );
        if (attempt > 0 || !_isStreamLoaded) {
          await _player.stop();
          _isStreamLoaded = false;
        }
        await _ensureStreamReady();
        _playWithoutBlocking();

        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (_player.playing) break;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر استئناف البث تلقائيا، اضغط تشغيل مرة أخرى.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      _isRecoveringPlayback = false;
    }
  }

  Future<void> _loadStream() async {
    final artworkUri = await _nowPlayingArtworkUri();

    await _player.setAudioSource(
      AudioSource.uri(
        Uri.parse(_streamUrl),
        tag: MediaItem(
          id: _streamUrl,
          album: 'صندوق الزكاة الليبي',
          title: 'إذاعة صندوق الزكاة الليبي',
          artist: 'البث المباشر لصندوق الزكاة الليبي',
          artUri: artworkUri,
        ),
      ),
    );
  }

  Future<Uri?> _nowPlayingArtworkUri() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File('${directory.path}/zakat_now_playing_v2.png');
      final data = await rootBundle.load('assets/images/now_playing.png');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return Uri.file(file.path);
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureStreamReady() async {
    while (_isPreparingStream && !_isStreamLoaded) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_isStreamLoaded) return;

    _isPreparingStream = true;
    try {
      await _loadStream();
      _isStreamLoaded = true;
    } finally {
      _isPreparingStream = false;
    }
  }

  Future<void> _togglePlay() async {
    if (_isBusy) return;

    setState(() => _isBusy = true);

    try {
      if (_player.playing) {
        _userWantsPlayback = false;
        await _player.stop();
        _isStreamLoaded = false;
      } else {
        await _startPlayback();
      }
    } catch (_) {
      _userWantsPlayback = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر تشغيل البث حاليا، حاول مرة أخرى.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _startPlayback() async {
    _userWantsPlayback = true;
    await _ensureStreamReady();
    _playWithoutBlocking();
  }

  void _playWithoutBlocking() {
    unawaited(
      _player.play().catchError((_) {
        _userWantsPlayback = false;
        if (mounted) setState(() {});
      }),
    );
  }

  Future<void> _refreshStream() async {
    if (_isBusy) return;

    setState(() => _isBusy = true);
    final shouldResume = _player.playing;
    try {
      await _player.stop();
      _isStreamLoaded = false;
      _userWantsPlayback = shouldResume;
      if (shouldResume) {
        await _startPlayback();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر تحديث البث حاليا.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _stopPlaybackForExit() async {
    _userWantsPlayback = false;
    await _player.stop();
    _isStreamLoaded = false;
    if (mounted) setState(() {});
  }

  Future<void> _handleTvExitRequest() async {
    if (_isTvExitDialogOpen) return;

    if (!_player.playing && !_userWantsPlayback) {
      SystemNavigator.pop();
      return;
    }

    _isTvExitDialogOpen = true;
    final action = await showDialog<_TvExitAction>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F292D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(
              color: const Color(0xFFD5C09C).withValues(alpha: 0.32),
            ),
          ),
          title: const Text(
            'الخروج من التطبيق',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFD5C09C),
              fontWeight: FontWeight.w900,
            ),
          ),
          content: const Text(
            'هل تريد إبقاء البث شغالاً في الخلفية، أم إيقافه قبل الخروج؟',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFF7F2E8), height: 1.5),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _TvExitAction.cancel),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _TvExitAction.stop),
              child: const Text('إيقافه'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, _TvExitAction.keep),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD5C09C),
                foregroundColor: const Color(0xFF0F292D),
              ),
              child: const Text('الخلفية'),
            ),
          ],
        );
      },
    );
    _isTvExitDialogOpen = false;

    if (!mounted || action == null || action == _TvExitAction.cancel) return;

    if (action == _TvExitAction.stop) {
      await _stopPlaybackForExit();
    }

    SystemNavigator.pop();
  }

  void _setSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();

    setState(() {
      _sleepDuration = duration;
      _sleepRemaining = duration;
    });

    _sleepTimer = Timer(duration, () async {
      _userWantsPlayback = false;
      await _player.stop();
      _isStreamLoaded = false;
      if (mounted) {
        setState(() {
          _sleepDuration = null;
          _sleepRemaining = null;
        });
      }
    });

    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _sleepRemaining == null) return;

      final next = _sleepRemaining! - const Duration(seconds: 1);
      setState(() => _sleepRemaining = next.isNegative ? Duration.zero : next);

      if (next <= Duration.zero) {
        _sleepTicker?.cancel();
      }
    });
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    setState(() {
      _sleepDuration = null;
      _sleepRemaining = null;
    });
  }

  void _showSleepTimerSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F292D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'مؤقت النوم',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFD5C09C),
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 14),
                for (final minutes in const [15, 30, 60])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _SheetOption(
                      label: 'إيقاف بعد $minutes دقيقة',
                      icon: Icons.timer_rounded,
                      onTap: () {
                        Navigator.pop(context);
                        _setSleepTimer(Duration(minutes: minutes));
                      },
                    ),
                  ),
                if (_sleepDuration != null)
                  _SheetOption(
                    label: 'إلغاء المؤقت',
                    icon: Icons.timer_off_rounded,
                    onTap: () {
                      Navigator.pop(context);
                      _cancelSleepTimer();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSleepTimerPicker() {
    if (_isTelevisionLayout(context)) {
      _showTvSleepTimerDialog();
      return;
    }

    _showSleepTimerSheet();
  }

  void _openAdminLogin() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AdminLoginPage()));
  }

  void _showTvSleepTimerDialog() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF0F292D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
            side: BorderSide(
              color: const Color(0xFFD5C09C).withValues(alpha: 0.28),
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'مؤقت النوم',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFD5C09C),
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 20),
                  for (final minutes in const [15, 30, 60])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _TvSheetOption(
                        label: 'إيقاف بعد $minutes دقيقة',
                        icon: Icons.timer_rounded,
                        onTap: () {
                          Navigator.pop(context);
                          _setSleepTimer(Duration(minutes: minutes));
                        },
                      ),
                    ),
                  if (_sleepDuration != null)
                    _TvSheetOption(
                      label: 'إلغاء المؤقت',
                      icon: Icons.timer_off_rounded,
                      onTap: () {
                        Navigator.pop(context);
                        _cancelSleepTimer();
                      },
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    final didLaunch = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!didLaunch && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تعذر فتح الرابط حاليا.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openWasl() async {
    if (Platform.isAndroid) {
      var openedApp = false;
      try {
        openedApp =
            await _nativeChannel.invokeMethod<bool>(
              'openApp',
              _waslPackageName,
            ) ??
            false;
      } catch (_) {
        openedApp = false;
      }

      if (openedApp) return;
      await _openLink(_waslStoreUrl);
      return;
    }

    await _openLink(_waslFallbackUrl);
  }

  void _showSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F292D),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'الإعدادات',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFFD5C09C),
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'جودة الحركة',
                      style: TextStyle(
                        color: Color(0xFFEADDBD),
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _SettingsChoice(
                            label: 'كاملة',
                            selected: _motionQuality == _MotionQuality.full,
                            onTap: () async {
                              await _saveMotionQuality(_MotionQuality.full);
                              setSheetState(() {});
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _SettingsChoice(
                            label: 'متوازنة',
                            selected: _motionQuality == _MotionQuality.balanced,
                            onTap: () async {
                              await _saveMotionQuality(_MotionQuality.balanced);
                              setSheetState(() {});
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _SettingsChoice(
                            label: 'أداء',
                            selected: _motionQuality == _MotionQuality.saver,
                            onTap: () async {
                              await _saveMotionQuality(_MotionQuality.saver);
                              setSheetState(() {});
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SwitchListTile.adaptive(
                      value: _autoPlayOnLaunch,
                      onChanged: (value) async {
                        await _saveAutoPlay(value);
                        setSheetState(() {});
                      },
                      activeColor: const Color(0xFFD5C09C),
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'تشغيل تلقائي عند فتح التطبيق',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _SheetOption(
                      label: 'تحديث البث',
                      icon: Icons.refresh_rounded,
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(_refreshStream());
                      },
                    ),
                    const SizedBox(height: 10),
                    _SheetOption(
                      label: 'موقع الإذاعة على الويب',
                      icon: Icons.radio_rounded,
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(_openLink('https://radio.zakatfund.gov.ly/'));
                      },
                    ),
                    const SizedBox(height: 10),
                    _SheetOption(
                      label: 'موقع صندوق الزكاة',
                      icon: Icons.language_rounded,
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(_openLink('https://zakatfund.gov.ly/'));
                      },
                    ),
                    const SizedBox(height: 10),
                    _SheetOption(
                      label: 'موقع منصة وصل الليبية',
                      icon: Icons.public_rounded,
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(_openLink('https://wasl.zakatfund.gov.ly/'));
                      },
                    ),
                    const SizedBox(height: 10),
                    _SheetOption(
                      label: 'حول التطبيق',
                      icon: Icons.info_outline_rounded,
                      onTap: () {
                        Navigator.pop(context);
                        _showAboutAppDialog();
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showAboutAppDialog() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F292D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(
              color: const Color(0xFFD5C09C).withValues(alpha: 0.28),
            ),
          ),
          title: const Text(
            'إذاعة صندوق الزكاة الليبي',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFD5C09C),
              fontWeight: FontWeight.w900,
            ),
          ),
          content: const Text(
            'تطبيق بث مباشر لإذاعة صندوق الزكاة الليبي.\nالإصدار 1.0.0',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFF7F2E8), height: 1.6),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('تم'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    _interruptionSubscription?.cancel();
    _playingSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = _scaleFor(context);
    final isTelevision = _isTelevisionLayout(context);

    return PopScope(
      canPop: !isTelevision,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !isTelevision) return;
        unawaited(_handleTvExitRequest());
      },
      child: Scaffold(
        body: Stack(
          children: [
            _RadioBackground(animate: _animateBackground),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      18 * scale,
                      14 * scale,
                      18 * scale,
                      16 * scale,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isTelevision ? 720 : 620,
                          minHeight: constraints.maxHeight - (30 * scale),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _RadioCard(
                              player: _player,
                              isBusy: _isBusy,
                              wantsPlayback: _userWantsPlayback,
                              scale: scale,
                              showSettingsButton: !isTelevision,
                              animateHero: _animateHero,
                              animateLivePill: _animateLivePill,
                              animateWaves: _animateWaves,
                              onTogglePlay: _togglePlay,
                              onSettingsPressed: _showSettingsSheet,
                              onSettingsHoldComplete: _openAdminLogin,
                            ),
                            SizedBox(height: 14 * scale),
                            if (isTelevision)
                              _TvBottomDock(
                                scale: scale,
                                sleepDuration: _sleepDuration,
                                sleepRemaining: _sleepRemaining,
                                onSleepTimerPressed: _showSleepTimerPicker,
                              )
                            else
                              _BottomDock(
                                scale: scale,
                                sleepDuration: _sleepDuration,
                                sleepRemaining: _sleepRemaining,
                                onSleepTimerPressed: _showSleepTimerPicker,
                                onFacebookPressed: () => _openLink(
                                  'https://www.facebook.com/zakatlibya',
                                ),
                                onTelegramPressed: () =>
                                    _openLink('https://t.me/zakatlibya'),
                                onWaslPressed: _openWasl,
                              ),
                            if (!isTelevision) ...[
                              SizedBox(height: 10 * scale),
                              Text(
                                'صندوق الزكاة الليبي | إذاعة الزكاة',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.68),
                                  fontSize: 12.5 * scale,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadioBackground extends StatefulWidget {
  const _RadioBackground({required this.animate});

  final bool animate;

  @override
  State<_RadioBackground> createState() => _RadioBackgroundState();
}

class _RadioBackgroundState extends State<_RadioBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _RadioBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.animate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate) return _buildBackground(progress: 0);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) =>
          _buildBackground(progress: _controller.value),
    );
  }

  Widget _buildBackground({required double progress}) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1D4549), Color(0xFF153439), Color(0xFF0F292D)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: -110,
            top: -120,
            child: _GlowCircle(
              size: 280,
              color: const Color(0xFFD5C09C).withValues(alpha: 0.2),
            ),
          ),
          Positioned(
            right: -120,
            bottom: -130,
            child: _GlowCircle(
              size: 310,
              color: const Color(0xFF4EA49B).withValues(alpha: 0.18),
            ),
          ),
          Positioned(
            right: -150,
            top: 90,
            child: _RingAccent(size: 240, opacity: 0.12),
          ),
          Positioned(
            left: -130,
            bottom: 100,
            child: _RingAccent(size: 190, opacity: 0.08),
          ),
          CustomPaint(
            painter: _ParticlesPainter(progress: progress),
            size: Size.infinite,
          ),
        ],
      ),
    );
  }
}

class _RingAccent extends StatelessWidget {
  const _RingAccent({required this.size, required this.opacity});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: const Color(0xFFD5C09C).withValues(alpha: opacity),
          width: 1.4,
        ),
      ),
    );
  }
}

class _GlowCircle extends StatelessWidget {
  const _GlowCircle({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
      ),
    );
  }
}

class _ParticlesPainter extends CustomPainter {
  const _ParticlesPainter({required this.progress});

  final double progress;

  static const _particles = [
    _Particle(seedX: 0.12, seedY: 0.18, radius: 26, drift: 28, phase: 0.0),
    _Particle(seedX: 0.78, seedY: 0.16, radius: 18, drift: 22, phase: 0.2),
    _Particle(seedX: 0.22, seedY: 0.42, radius: 14, drift: 20, phase: 0.4),
    _Particle(seedX: 0.86, seedY: 0.48, radius: 30, drift: 34, phase: 0.6),
    _Particle(seedX: 0.16, seedY: 0.72, radius: 22, drift: 26, phase: 0.8),
    _Particle(seedX: 0.68, seedY: 0.76, radius: 15, drift: 24, phase: 1.0),
    _Particle(seedX: 0.45, seedY: 0.28, radius: 12, drift: 18, phase: 0.35),
    _Particle(seedX: 0.52, seedY: 0.92, radius: 24, drift: 30, phase: 0.7),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (final particle in _particles) {
      final angle = (progress + particle.phase) * math.pi * 2;
      final center = Offset(
        (particle.seedX * size.width) + math.cos(angle) * particle.drift,
        (particle.seedY * size.height) +
            math.sin(angle * 0.85) * particle.drift,
      );
      final rect = Rect.fromCircle(center: center, radius: particle.radius);
      final color = particle.phase > 0.55
          ? const Color(0xFF7BC3B6)
          : const Color(0xFFD5C09C);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.16),
            color.withValues(alpha: 0.04),
            color.withValues(alpha: 0),
          ],
        ).createShader(rect);

      canvas.drawCircle(center, particle.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlesPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class _Particle {
  const _Particle({
    required this.seedX,
    required this.seedY,
    required this.radius,
    required this.drift,
    required this.phase,
  });

  final double seedX;
  final double seedY;
  final double radius;
  final double drift;
  final double phase;
}

class _RadioCard extends StatelessWidget {
  const _RadioCard({
    required this.player,
    required this.isBusy,
    required this.wantsPlayback,
    required this.scale,
    required this.showSettingsButton,
    required this.animateHero,
    required this.animateLivePill,
    required this.animateWaves,
    required this.onTogglePlay,
    required this.onSettingsPressed,
    required this.onSettingsHoldComplete,
  });

  final AudioPlayer player;
  final bool isBusy;
  final bool wantsPlayback;
  final double scale;
  final bool showSettingsButton;
  final bool animateHero;
  final bool animateLivePill;
  final bool animateWaves;
  final VoidCallback onTogglePlay;
  final VoidCallback onSettingsPressed;
  final VoidCallback onSettingsHoldComplete;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: player.playerStateStream,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final isPlaying = state?.playing ?? player.playing;
        final isBuffering =
            state?.processingState == ProcessingState.loading ||
            state?.processingState == ProcessingState.buffering;
        final isLoading =
            wantsPlayback && !isPlaying && (isBusy || isBuffering);

        return ClipRRect(
          borderRadius: BorderRadius.circular(28 * scale),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              20 * scale,
              24 * scale,
              20 * scale,
              22 * scale,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF0F292D).withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(28 * scale),
              border: Border.all(
                color: const Color(0xFFD5C09C).withValues(alpha: 0.34),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.42),
                  blurRadius: 70 * scale,
                  offset: Offset(0, 28 * scale),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LivePill(scale: scale, animate: animateLivePill),
                SizedBox(height: 14 * scale),
                _HeroLogo(
                  isPlaying: isPlaying,
                  isLoading: isLoading,
                  scale: scale,
                  animate: animateHero,
                ),
                SizedBox(height: 14 * scale),
                Text(
                  'إذاعة\nصندوق الزكاة الليبي',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: const Color(0xFFD5C09C),
                    fontSize: 31 * scale,
                    fontWeight: FontWeight.w900,
                    height: 1.16,
                  ),
                ),
                SizedBox(height: 10 * scale),
                Text(
                  'إذاعة صوتية توعوية تبث البرامج الدعوية وأحكام الزكاة، وتسهم في نشر الوعي وخدمة المجتمع.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: const Color(0xFFF7F2E8),
                    fontSize: 14.5 * scale,
                    height: 1.55,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 18 * scale),
                _AudioBox(
                  isPlaying: isPlaying,
                  isLoading: isLoading,
                  scale: scale,
                  showSettingsButton: showSettingsButton,
                  animateWaves: animateWaves,
                  onTogglePlay: onTogglePlay,
                  onSettingsPressed: onSettingsPressed,
                  onSettingsHoldComplete: onSettingsHoldComplete,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HeroLogo extends StatefulWidget {
  const _HeroLogo({
    required this.isPlaying,
    required this.isLoading,
    required this.scale,
    required this.animate,
  });

  final bool isPlaying;
  final bool isLoading;
  final double scale;
  final bool animate;

  @override
  State<_HeroLogo> createState() => _HeroLogoState();
}

class _HeroLogoState extends State<_HeroLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    if (widget.animate && (widget.isPlaying || widget.isLoading)) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _HeroLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldAnimate =
        widget.animate && (widget.isPlaying || widget.isLoading);
    if (shouldAnimate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldAnimate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scale;
    final isActive = widget.animate && (widget.isPlaying || widget.isLoading);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final pulse = isActive
            ? 1 + (math.sin(_controller.value * math.pi * 2) * 0.025)
            : 1.0;

        return SizedBox(
          width: 220 * scale,
          height: 220 * scale,
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (var index = 0; index < 3; index++)
                Transform.scale(
                  scale: pulse + (index * 0.16),
                  child: Container(
                    width: 145 * scale,
                    height: 145 * scale,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFD5C09C).withValues(
                          alpha: isActive ? 0.22 - (index * 0.05) : 0.08,
                        ),
                        width: 1.4,
                      ),
                    ),
                  ),
                ),
              Transform.rotate(
                angle: widget.isLoading ? _controller.value * math.pi * 2 : 0,
                child: Container(
                  width: 176 * scale,
                  height: 176 * scale,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      colors: [
                        const Color(0xFFD5C09C).withValues(alpha: 0.12),
                        const Color(
                          0xFFD5C09C,
                        ).withValues(alpha: isActive ? 0.8 : 0.32),
                        const Color(0xFF4EA49B).withValues(alpha: 0.16),
                        const Color(0xFFD5C09C).withValues(alpha: 0.12),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(
                          0xFFD5C09C,
                        ).withValues(alpha: isActive ? 0.24 : 0.12),
                        blurRadius: isActive ? 46 * scale : 28 * scale,
                        offset: Offset(0, 16 * scale),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                width: 158 * scale,
                height: 158 * scale,
                padding: EdgeInsets.all(8 * scale),
                decoration: BoxDecoration(
                  color: const Color(0xFF123236),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFEADDBD).withValues(alpha: 0.5),
                    width: 1.4,
                  ),
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/images/logo.png',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              Positioned(
                bottom: 16 * scale,
                child: _HeroStatusChip(
                  isPlaying: widget.isPlaying,
                  isLoading: widget.isLoading,
                  scale: scale,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HeroStatusChip extends StatelessWidget {
  const _HeroStatusChip({
    required this.isPlaying,
    required this.isLoading,
    required this.scale,
  });

  final bool isPlaying;
  final bool isLoading;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final label = isLoading
        ? 'جاري الاتصال'
        : (isPlaying ? 'مباشر الآن' : 'جاهز للبث');

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 13 * scale,
        vertical: 7 * scale,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0F292D).withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFFD5C09C).withValues(alpha: 0.42),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: const Color(0xFFEADDBD),
          fontSize: 12 * scale,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _LivePill extends StatefulWidget {
  const _LivePill({required this.scale, required this.animate});

  final double scale;
  final bool animate;

  @override
  State<_LivePill> createState() => _LivePillState();
}

class _LivePillState extends State<_LivePill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
      lowerBound: 0.82,
      upperBound: 1,
    );
    if (widget.animate) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _LivePill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.animate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 22 * widget.scale,
        vertical: 8 * widget.scale,
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFEADDBD), Color(0xFFD5C09C)],
        ),
        borderRadius: BorderRadius.circular(30 * widget.scale),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 22 * widget.scale,
            offset: Offset(0, 9 * widget.scale),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ScaleTransition(
            scale: _controller,
            child: Container(
              width: 8 * widget.scale,
              height: 8 * widget.scale,
              decoration: BoxDecoration(
                color: const Color(0xFFD52323),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFD52323).withValues(alpha: 0.22),
                    blurRadius: 9 * widget.scale,
                    spreadRadius: 4 * widget.scale,
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: 8 * widget.scale),
          Text(
            'البث المباشر',
            style: TextStyle(
              color: const Color(0xFF0F292D),
              fontSize: 14 * widget.scale,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioBox extends StatelessWidget {
  const _AudioBox({
    required this.isPlaying,
    required this.isLoading,
    required this.scale,
    required this.showSettingsButton,
    required this.animateWaves,
    required this.onTogglePlay,
    required this.onSettingsPressed,
    required this.onSettingsHoldComplete,
  });

  final bool isPlaying;
  final bool isLoading;
  final double scale;
  final bool showSettingsButton;
  final bool animateWaves;
  final VoidCallback onTogglePlay;
  final VoidCallback onSettingsPressed;
  final VoidCallback onSettingsHoldComplete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(24 * scale),
        border: Border.all(
          color: const Color(0xFFD5C09C).withValues(alpha: 0.28),
        ),
      ),
      child: Column(
        children: [
          Row(
            textDirection: TextDirection.rtl,
            children: [
              Expanded(
                child: _WidePlayButton(
                  isPlaying: isPlaying,
                  isLoading: isLoading,
                  scale: scale,
                  onPressed: onTogglePlay,
                ),
              ),
              if (showSettingsButton) ...[
                SizedBox(width: 10 * scale),
                _AdminHoldArea(
                  onTap: onSettingsPressed,
                  onComplete: onSettingsHoldComplete,
                  child: _SettingsSquareButton(scale: scale, onPressed: () {}),
                ),
              ],
            ],
          ),
          SizedBox(height: 14 * scale),
          _AudioHeader(
            isPlaying: isPlaying,
            isLoading: isLoading,
            scale: scale,
            animateWaves: animateWaves,
          ),
        ],
      ),
    );
  }
}

class _WidePlayButton extends StatelessWidget {
  const _WidePlayButton({
    required this.isPlaying,
    required this.isLoading,
    required this.scale,
    required this.onPressed,
  });

  final bool isPlaying;
  final bool isLoading;
  final double scale;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final activeColor = isPlaying ? Colors.white : const Color(0xFF0F292D);
    final gradient = isPlaying
        ? const LinearGradient(colors: [Color(0xFF2F716C), Color(0xFF1D4549)])
        : const LinearGradient(colors: [Color(0xFFEADDBD), Color(0xFFD5C09C)]);

    return SizedBox(
      width: double.infinity,
      height: 58 * scale,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(18 * scale),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.24),
              blurRadius: 26 * scale,
              offset: Offset(0, 14 * scale),
            ),
          ],
        ),
        child: TextButton(
          onPressed: isLoading ? null : onPressed,
          style: TextButton.styleFrom(
            foregroundColor: activeColor,
            disabledForegroundColor: const Color(0xFF0F292D),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18 * scale),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _PlayIcon(
                isPlaying: isPlaying,
                isLoading: isLoading,
                color: activeColor,
                scale: scale,
              ),
              SizedBox(width: 12 * scale),
              Text(
                isPlaying ? 'إيقاف البث' : 'تشغيل البث',
                style: TextStyle(
                  fontSize: 17 * scale,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSquareButton extends StatelessWidget {
  const _SettingsSquareButton({required this.scale, required this.onPressed});

  final double scale;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final size = 58 * scale;

    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: const Color(0xFF0F292D).withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(18 * scale),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(18 * scale),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18 * scale),
              border: Border.all(
                color: const Color(0xFFD5C09C).withValues(alpha: 0.32),
              ),
            ),
            child: Icon(
              Icons.settings_rounded,
              color: const Color(0xFFD5C09C),
              size: 24 * scale,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayIcon extends StatelessWidget {
  const _PlayIcon({
    required this.isPlaying,
    required this.isLoading,
    required this.color,
    required this.scale,
  });

  final bool isPlaying;
  final bool isLoading;
  final Color color;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32 * scale,
      height: 32 * scale,
      decoration: BoxDecoration(
        color: const Color(0xFF0F292D).withValues(alpha: 0.16),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: isLoading
            ? SizedBox(
                width: 18 * scale,
                height: 18 * scale,
                child: CircularProgressIndicator(strokeWidth: 2.6 * scale),
              )
            : Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: color,
                size: 24 * scale,
              ),
      ),
    );
  }
}

class _AudioHeader extends StatelessWidget {
  const _AudioHeader({
    required this.isPlaying,
    required this.isLoading,
    required this.scale,
    required this.animateWaves,
  });

  final bool isPlaying;
  final bool isLoading;
  final double scale;
  final bool animateWaves;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 14 * scale,
      runSpacing: 10 * scale,
      children: [
        Text(
          'استمع الآن إلى البث المباشر',
          style: TextStyle(
            color: const Color(0xFFEADDBD),
            fontSize: 14 * scale,
            fontWeight: FontWeight.w900,
          ),
        ),
        _MiniWaves(
          isPlaying: isPlaying,
          isLoading: isLoading,
          scale: scale,
          animate: animateWaves,
        ),
      ],
    );
  }
}

class _MiniWaves extends StatefulWidget {
  const _MiniWaves({
    required this.isPlaying,
    required this.isLoading,
    required this.scale,
    required this.animate,
  });

  final bool isPlaying;
  final bool isLoading;
  final double scale;
  final bool animate;

  @override
  State<_MiniWaves> createState() => _MiniWavesState();
}

class _MiniWavesState extends State<_MiniWaves>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    if (widget.animate && (widget.isPlaying || widget.isLoading)) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _MiniWaves oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldAnimate =
        widget.animate && (widget.isPlaying || widget.isLoading);
    if (shouldAnimate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldAnimate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading && widget.animate) {
      return RotationTransition(
        turns: _controller,
        child: SizedBox(
          width: 22 * widget.scale,
          height: 22 * widget.scale,
          child: CircularProgressIndicator(
            strokeWidth: 3 * widget.scale,
            color: const Color(0xFFD5C09C),
            backgroundColor: const Color(0xFFD5C09C).withValues(alpha: 0.28),
          ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return SizedBox(
          height: 24 * widget.scale,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(4, (index) {
              final wave = math.sin(
                (_controller.value * math.pi * 2) + (index * 0.75),
              );
              final height = widget.isPlaying && widget.animate
                  ? (10 + ((wave + 1) / 2 * 12)) * widget.scale
                  : 10 * widget.scale;

              return Container(
                width: 5 * widget.scale,
                height: height,
                margin: EdgeInsets.symmetric(horizontal: 2 * widget.scale),
                decoration: BoxDecoration(
                  color: const Color(0xFFD5C09C),
                  borderRadius: BorderRadius.circular(10 * widget.scale),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

class _TvBottomDock extends StatelessWidget {
  const _TvBottomDock({
    required this.scale,
    required this.sleepDuration,
    required this.sleepRemaining,
    required this.onSleepTimerPressed,
  });

  final double scale;
  final Duration? sleepDuration;
  final Duration? sleepRemaining;
  final VoidCallback onSleepTimerPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 210 * scale,
          maxWidth: 340 * scale,
        ),
        child: _TvTimerButton(
          icon: sleepDuration == null
              ? Icons.bedtime_rounded
              : Icons.timer_rounded,
          label: _sleepLabel(),
          scale: scale,
          onPressed: onSleepTimerPressed,
        ),
      ),
    );
  }

  String _sleepLabel() {
    final remainingTime = sleepRemaining ?? sleepDuration;
    if (remainingTime == null) return 'المؤقت';

    final totalSeconds = remainingTime.inSeconds.clamp(0, 24 * 60 * 60);
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _TvTimerButton extends StatelessWidget {
  const _TvTimerButton({
    required this.icon,
    required this.label,
    required this.scale,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final double scale;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0F292D).withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(24 * scale),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(24 * scale),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: 28 * scale,
            vertical: 18 * scale,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24 * scale),
            border: Border.all(
              color: const Color(0xFFD5C09C).withValues(alpha: 0.36),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 24 * scale,
                offset: Offset(0, 10 * scale),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: const Color(0xFFD5C09C), size: 30 * scale),
              SizedBox(width: 12 * scale),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20 * scale,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomDock extends StatelessWidget {
  const _BottomDock({
    required this.scale,
    required this.sleepDuration,
    required this.sleepRemaining,
    required this.onSleepTimerPressed,
    required this.onFacebookPressed,
    required this.onTelegramPressed,
    required this.onWaslPressed,
  });

  final double scale;
  final Duration? sleepDuration;
  final Duration? sleepRemaining;
  final VoidCallback onSleepTimerPressed;
  final VoidCallback onFacebookPressed;
  final VoidCallback onTelegramPressed;
  final VoidCallback onWaslPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 10 * scale,
        vertical: 10 * scale,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0F292D).withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(24 * scale),
        border: Border.all(
          color: const Color(0xFFD5C09C).withValues(alpha: 0.22),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 26 * scale,
            offset: Offset(0, 12 * scale),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _DockAction(
              icon: sleepDuration == null
                  ? Icons.bedtime_rounded
                  : Icons.timer_rounded,
              label: _sleepLabel(),
              scale: scale,
              onPressed: onSleepTimerPressed,
            ),
          ),
          SizedBox(width: 8 * scale),
          Expanded(
            child: _DockAction(
              icon: Icons.facebook,
              label: 'فيسبوك',
              scale: scale,
              onPressed: onFacebookPressed,
            ),
          ),
          SizedBox(width: 8 * scale),
          Expanded(
            child: _DockAction(
              icon: Icons.send_rounded,
              label: 'تيليجرام',
              scale: scale,
              onPressed: onTelegramPressed,
            ),
          ),
          SizedBox(width: 8 * scale),
          Expanded(
            child: _DockAction(
              assetIcon: 'assets/images/wasl.png',
              label: 'وصل',
              scale: scale,
              onPressed: onWaslPressed,
            ),
          ),
        ],
      ),
    );
  }

  String _sleepLabel() {
    final remainingTime = sleepRemaining ?? sleepDuration;
    if (remainingTime == null) return 'المؤقت';

    final totalSeconds = remainingTime.inSeconds.clamp(0, 24 * 60 * 60);
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _AdminHoldArea extends StatefulWidget {
  const _AdminHoldArea({
    required this.child,
    required this.onTap,
    required this.onComplete,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onComplete;

  @override
  State<_AdminHoldArea> createState() => _AdminHoldAreaState();
}

class _AdminHoldAreaState extends State<_AdminHoldArea> {
  Timer? _holdTimer;
  bool _suppressNextTap = false;

  void _startHold() {
    _holdTimer?.cancel();
    _suppressNextTap = false;
    _holdTimer = Timer(const Duration(seconds: 10), () {
      _suppressNextTap = true;
      HapticFeedback.heavyImpact();
      widget.onComplete();
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  @override
  void dispose() {
    _cancelHold();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _startHold(),
      onTapUp: (_) => _cancelHold(),
      onTapCancel: _cancelHold,
      onTap: () {
        if (_suppressNextTap) {
          _suppressNextTap = false;
          return;
        }
        widget.onTap();
      },
      child: IgnorePointer(child: widget.child),
    );
  }
}

class _DockAction extends StatelessWidget {
  const _DockAction({
    this.icon,
    this.assetIcon,
    required this.label,
    required this.scale,
    required this.onPressed,
  });

  final IconData? icon;
  final String? assetIcon;
  final String label;
  final double scale;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.055),
      borderRadius: BorderRadius.circular(18 * scale),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(18 * scale),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 10 * scale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (assetIcon == null)
                Icon(icon, color: const Color(0xFFD5C09C), size: 22 * scale)
              else
                ImageIcon(
                  AssetImage(assetIcon!),
                  color: const Color(0xFFD5C09C),
                  size: 22 * scale,
                ),
              SizedBox(height: 4 * scale),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.86),
                  fontSize: 11.5 * scale,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvSheetOption extends StatelessWidget {
  const _TvSheetOption({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child: Row(
            children: [
              Icon(icon, color: const Color(0xFFD5C09C), size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetOption extends StatelessWidget {
  const _SheetOption({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: const Color(0xFFD5C09C)),
      title: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      tileColor: Colors.white.withValues(alpha: 0.06),
    );
  }
}

class _SettingsChoice extends StatelessWidget {
  const _SettingsChoice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? const Color(0xFFD5C09C)
          : Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? const Color(0xFFEADDBD)
                  : const Color(0xFFD5C09C).withValues(alpha: 0.24),
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? const Color(0xFF0F292D) : Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
