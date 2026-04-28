import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'ly.zakat.radio.audio',
    androidNotificationChannelName: 'إذاعة صندوق الزكاة الليبي',
    androidNotificationOngoing: true,
  );
  runApp(const MyApp());
}

double _scaleFor(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return math
      .min(size.width / 390, size.height / 760)
      .clamp(0.78, 1.0)
      .toDouble();
}

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

class _RadioPageState extends State<RadioPage> {
  final AudioPlayer _player = AudioPlayer();
  final String _streamUrl =
      'https://radio.zakatfund.gov.ly/listen/zakat/radio.mp3';

  bool _isBusy = false;
  Timer? _sleepTimer;
  Timer? _sleepTicker;
  Duration? _sleepDuration;
  Duration? _sleepRemaining;

  Future<void> _togglePlay() async {
    if (_isBusy) return;

    setState(() => _isBusy = true);

    try {
      if (_player.playing) {
        await _player.stop();
      } else {
        await _player.setAudioSource(
          AudioSource.uri(
            Uri.parse(_streamUrl),
            tag: MediaItem(
              id: _streamUrl,
              album: 'صندوق الزكاة الليبي',
              title: 'إذاعة صندوق الزكاة الليبي',
              artist: 'البث المباشر لصندوق الزكاة الليبي',
            ),
          ),
        );
        unawaited(_player.play());
      }
    } catch (_) {
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

  void _setSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();

    setState(() {
      _sleepDuration = duration;
      _sleepRemaining = duration;
    });

    _sleepTimer = Timer(duration, () async {
      await _player.stop();
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

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    final didLaunch = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!didLaunch && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تعذر فتح الرابط حاليا.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = _scaleFor(context);

    return Scaffold(
      body: Stack(
        children: [
          const _RadioBackground(),
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
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 620,
                      minHeight: constraints.maxHeight - (30 * scale),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _RadioCard(
                          player: _player,
                          isBusy: _isBusy,
                          scale: scale,
                          onTogglePlay: _togglePlay,
                        ),
                        SizedBox(height: 14 * scale),
                        _BottomDock(
                          scale: scale,
                          sleepDuration: _sleepDuration,
                          sleepRemaining: _sleepRemaining,
                          onSleepTimerPressed: _showSleepTimerSheet,
                          onFacebookPressed: () =>
                              _openLink('https://www.facebook.com/zakatlibya'),
                          onTelegramPressed: () =>
                              _openLink('https://t.me/zakatlibya'),
                        ),
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
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RadioBackground extends StatefulWidget {
  const _RadioBackground();

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
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF1D4549),
                Color(0xFF153439),
                Color(0xFF0F292D),
              ],
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
                painter: _ParticlesPainter(progress: _controller.value),
                size: Size.infinite,
              ),
            ],
          ),
        );
      },
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
        (particle.seedY * size.height) + math.sin(angle * 0.85) * particle.drift,
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
    required this.scale,
    required this.onTogglePlay,
  });

  final AudioPlayer player;
  final bool isBusy;
  final double scale;
  final VoidCallback onTogglePlay;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: player.playerStateStream,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final isPlaying = state?.playing ?? player.playing;
        final isLoading =
            state?.processingState == ProcessingState.loading ||
                state?.processingState == ProcessingState.buffering ||
                isBusy;

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
                _LivePill(scale: scale),
                SizedBox(height: 14 * scale),
                _HeroLogo(
                  isPlaying: isPlaying,
                  isLoading: isLoading,
                  scale: scale,
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
                  onTogglePlay: onTogglePlay,
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
  });

  final bool isPlaying;
  final bool isLoading;
  final double scale;

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
    if (widget.isPlaying || widget.isLoading) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _HeroLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldAnimate = widget.isPlaying || widget.isLoading;
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
    final isActive = widget.isPlaying || widget.isLoading;

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
                        const Color(0xFFD5C09C).withValues(
                          alpha: isActive ? 0.8 : 0.32,
                        ),
                        const Color(0xFF4EA49B).withValues(alpha: 0.16),
                        const Color(0xFFD5C09C).withValues(alpha: 0.12),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFD5C09C).withValues(
                          alpha: isActive ? 0.24 : 0.12,
                        ),
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
                  child: Image.asset('assets/images/logo.png', fit: BoxFit.cover),
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
    final label = isLoading ? 'جاري الاتصال' : (isPlaying ? 'مباشر الآن' : 'جاهز للبث');

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 13 * scale, vertical: 7 * scale),
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
  const _LivePill({required this.scale});

  final double scale;

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
    )..repeat(reverse: true);
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
    required this.onTogglePlay,
  });

  final bool isPlaying;
  final bool isLoading;
  final double scale;
  final VoidCallback onTogglePlay;

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
          _WidePlayButton(
            isPlaying: isPlaying,
            isLoading: isLoading,
            scale: scale,
            onPressed: onTogglePlay,
          ),
          SizedBox(height: 14 * scale),
          _AudioHeader(
            isPlaying: isPlaying,
            isLoading: isLoading,
            scale: scale,
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
  });

  final bool isPlaying;
  final bool isLoading;
  final double scale;

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
  });

  final bool isPlaying;
  final bool isLoading;
  final double scale;

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
    if (widget.isPlaying || widget.isLoading) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _MiniWaves oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldAnimate = widget.isPlaying || widget.isLoading;
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
    if (widget.isLoading) {
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
              final height = widget.isPlaying
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

class _BottomDock extends StatelessWidget {
  const _BottomDock({
    required this.scale,
    required this.sleepDuration,
    required this.sleepRemaining,
    required this.onSleepTimerPressed,
    required this.onFacebookPressed,
    required this.onTelegramPressed,
  });

  final double scale;
  final Duration? sleepDuration;
  final Duration? sleepRemaining;
  final VoidCallback onSleepTimerPressed;
  final VoidCallback onFacebookPressed;
  final VoidCallback onTelegramPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 10 * scale),
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

class _DockAction extends StatelessWidget {
  const _DockAction({
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
              Icon(icon, color: const Color(0xFFD5C09C), size: 22 * scale),
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
