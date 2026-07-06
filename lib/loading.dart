import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Vegas Life splash / loader screen.
///
/// Usage:
///   Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const VLLoaderScreen()));
///
/// Put your exported background (the black bg with the orange/white "VL"
/// brush-stroke logo and the Vegas skyline) into your project assets, e.g.:
///   assets/images/vl_splash_bg.png
/// and register it in pubspec.yaml:
///   flutter:
///     assets:
///       - assets/images/vl_splash_bg.png
class VLLoaderScreen extends StatefulWidget {
  const VLLoaderScreen({super.key, this.backgroundAsset = 'assets/bgvegas.png'});

  final String backgroundAsset;

  @override
  State<VLLoaderScreen> createState() => _VLLoaderScreenState();
}

class _VLLoaderScreenState extends State<VLLoaderScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background artwork.
          Image.asset(
            widget.backgroundAsset,
            fit: BoxFit.cover,
          ),

          // Subtle dark gradient so the loader always stays readable
          // regardless of what's behind it.
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.transparent,
                  Color(0xCC000000),
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),

          // Loader anchored near the bottom, above the skyline.
          Align(
            alignment: const Alignment(0, 0.78),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    return CustomPaint(
                      size: const Size(56, 56),
                      painter: _VLSpinnerPainter(progress: _controller.value),
                    );
                  },
                ),
                const SizedBox(height: 18),
                Text(
                  'LOADING',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painted spinner: a rotating yellow ring with a fading tail,
/// plus a soft glow, instead of the stock Material CircularProgressIndicator.
class _VLSpinnerPainter extends CustomPainter {
  _VLSpinnerPainter({required this.progress});

  final double progress;

  static const Color _yellow = Color(0xFFF5A623); // matches the VL brush-stroke orange

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 4;

    final rotation = progress * 2 * math.pi;

    // Soft glow behind the ring.
    final glowPaint = Paint()
      ..color = _yellow.withOpacity(0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);

    final rect = Rect.fromCircle(center: Offset.zero, radius: radius);

    // Faint full track.
    final trackPaint = Paint()
      ..color = Colors.white.withOpacity(0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawArc(rect, 0, 2 * math.pi, false, trackPaint);

    // Gradient sweep arc that fades out along its tail.
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 1.5,
        colors: [
          _yellow.withOpacity(0.0),
          _yellow.withOpacity(0.9),
        ],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, 0, math.pi * 1.5, false, glowPaint);
    canvas.drawArc(rect, 0, math.pi * 1.5, false, sweepPaint);

    // Small bright dot at the leading edge of the arc for extra polish.
    final dotAngle = math.pi * 1.5;
    final dotOffset = Offset(radius * math.cos(dotAngle), radius * math.sin(dotAngle));
    final dotPaint = Paint()
      ..color = Colors.white
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    canvas.drawCircle(dotOffset, 3, dotPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _VLSpinnerPainter oldDelegate) => oldDelegate.progress != progress;
}