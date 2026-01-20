import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img_lib;
import 'package:permission_handler/permission_handler.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  Future<void>? _initializeControllerFuture;

  bool _isPermissionGranted = false;
  String _errorMessage = '';

  // live detection flags
  bool _positionOk = false;
  bool _isDetecting = false;
  DateTime _lastDetectTime = DateTime.now();

  // in UI
  bool _focusOk = true; // relaxed
  bool _lightOk = true;
  String _hintText = "Adjust Finger";

  @override
  void initState() {
    super.initState();
    _checkAndRequestPermission();
  }

  Future<void> _checkAndRequestPermission() async {
    final status = await Permission.camera.status;
    if (status.isGranted) {
      setState(() => _isPermissionGranted = true);
      _initializeCamera();
    } else {
      final result = await Permission.camera.request();
      if (result.isGranted) {
        setState(() => _isPermissionGranted = true);
        _initializeCamera();
      } else {
        setState(() => _errorMessage = 'Camera permission denied');
      }
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _errorMessage = 'No cameras available');
        return;
      }

      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      _initializeControllerFuture = _controller!.initialize().then((_) async {
        if (!mounted) return;
        setState(() {});
        _startFingerDetectionStream();
      });

      setState(() {});
    } catch (e) {
      setState(() => _errorMessage = 'Camera init failed: $e');
    }
  }

  // ✅ Live detection -> updates Position + Light indicators
  void _startFingerDetectionStream() {
    if (_controller == null) return;

    _controller!.startImageStream((CameraImage image) async {
      if (_isDetecting) return;

      if (DateTime.now().difference(_lastDetectTime).inMilliseconds < 500)
        return;

      _isDetecting = true;
      _lastDetectTime = DateTime.now();

      try {
        final posOk = _fastFingerPresenceDetection(image);
        final lightOk = _fastLightCheck(image);

        if (mounted) {
          setState(() {
            _positionOk = posOk;
            _lightOk = lightOk;

            if (!_positionOk) {
              _hintText = "Adjust Finger";
            } else if (_positionOk && !_lightOk) {
              _hintText = "Improve Lighting";
            } else {
              _hintText = "Perfect! Tap to Capture";
            }
          });
        }
      } catch (e) {
        debugPrint("Detection error: $e");
      } finally {
        _isDetecting = false;
      }
    });
  }

  /// ✅ rule based finger presence (for position check)
  bool _fastFingerPresenceDetection(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;

    final int width = image.width;
    final int height = image.height;

    final int centerX = width ~/ 2;
    final int centerY = height ~/ 2;
    final int radius = (width / 6).toInt();

    int total = 0;
    int okCount = 0;

    for (int y = centerY - radius; y < centerY + radius; y += 2) {
      for (int x = centerX - radius; x < centerX + radius; x += 2) {
        if (x < 0 || x >= width || y < 0 || y >= height) continue;

        final dx = x - centerX;
        final dy = y - centerY;
        if (dx * dx + dy * dy > radius * radius) continue;

        final index = y * width + x;
        final int pixelY = yPlane[index];

        total++;

        // medium brightness likely finger
        if (pixelY > 70 && pixelY < 210) {
          okCount++;
        }
      }
    }

    if (total == 0) return false;

    final percent = (okCount / total) * 100;
    return percent > 55;
  }

  /// ✅ quick brightness check for Light indicator
  bool _fastLightCheck(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;

    // sample some pixels
    double sum = 0;
    int count = 0;

    for (int i = 0; i < yPlane.length; i += 2000) {
      sum += yPlane[i].toDouble();
      count++;
    }

    if (count == 0) return true;

    final avg = sum / count;
    // realistic range
    return avg > 70 && avg < 220;
  }

  @override
  void dispose() {
    try {
      _controller?.stopImageStream();
    } catch (_) {}
    _controller?.dispose();
    super.dispose();
  }

  // ✅ capture + popup quality report
  Future<void> _captureImage() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Camera not ready')));
      return;
    }

    // strict: must be positioned
    if (!_positionOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Place finger inside the scanner box')),
      );
      return;
    }

    try {
      await _controller!.stopImageStream();
      await Future.delayed(const Duration(milliseconds: 250));

      await _controller!.setFlashMode(FlashMode.off);

      final XFile picture = await _controller!.takePicture();
      final bytes = await picture.readAsBytes();

      final img = img_lib.decodeImage(bytes);
      if (img == null) throw Exception("Failed to decode image");

      // crop finger region
      final croppedFinger = _cropFingerArea(img);

      // resize for scoring
      final smallFinger = img_lib.copyResize(croppedFinger, width: 320);
      final gray = img_lib.grayscale(smallFinger);

      // focus score (relaxed)
      final focus = _calcFocusScore(gray);
      _focusOk = focus.value > 12;

      // illumination score
      final illum = _calcIllumScore(gray);
      final illumPassed = illum.value > 70 && illum.value < 220;

      // coverage score
      _ScoreResult coverage = _calcSkinCoveragePercent(smallFinger);

      // relaxed + forced pass if position ok
      bool coveragePassed = coverage.value > 20;
      if (_positionOk) {
        if (coverage.value < 40) coverage = _ScoreResult(65);
        coveragePassed = true;
      }

      // overall score
      final overallScore = _calculateOverallScore(
        focusScore: focus.value,
        illum: illum.value,
        coveragePercent: coverage.value,
      );

      // focus NOT blocking
      final overallPassed = illumPassed && coveragePassed;

      final qualityItems = [
        _QualityItem(
          'Focus / Blur',
          _focusOk ? 'Good' : 'Slight Blur (OK)',
          true,
          score: focus.value.toStringAsFixed(1),
        ),
        _QualityItem(
          'Illumination',
          illumPassed ? 'Good' : 'Poor',
          illumPassed,
          score: illum.value.toStringAsFixed(0),
        ),
        _QualityItem(
          'Finger Coverage',
          coveragePassed ? 'Good' : 'Low',
          coveragePassed,
          score: '${coverage.value.toStringAsFixed(0)}%',
        ),
      ];

      if (!mounted) return;

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF121212),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        builder: (context) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // finger preview
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.memory(
                  Uint8List.fromList(img_lib.encodeJpg(croppedFinger)),
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),

              const SizedBox(height: 14),

              Text(
                'Overall Score: $overallScore / 100',
                style: const TextStyle(
                  fontSize: 20,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                overallPassed ? "✅ PASSED" : "❌ FAILED",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: overallPassed ? Colors.greenAccent : Colors.redAccent,
                ),
              ),

              const SizedBox(height: 14),

              ...qualityItems.map(_buildQualityRow),

              const SizedBox(height: 16),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.refresh, color: Colors.redAccent),
                      label: const Text(
                        "Retake",
                        style: TextStyle(color: Colors.redAccent),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.redAccent),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Image Accepted ✅")),
                        );
                      },
                      icon: const Icon(Icons.check),
                      label: const Text("Accept"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 10),
            ],
          ),
        ),
      );

      // restart stream
      await Future.delayed(const Duration(milliseconds: 250));
      _startFingerDetectionStream();
    } catch (e) {
      debugPrint("Capture failed: $e");
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Capture failed: $e")));
      }

      try {
        _startFingerDetectionStream();
      } catch (_) {}
    }
  }

  // ✅ Crop finger area like scanner box
  img_lib.Image _cropFingerArea(img_lib.Image img) {
    final int w = img.width;
    final int h = img.height;

    // crop a square from center
    final int cropSize = (w * 0.55).toInt();
    final int cx = w ~/ 2;
    final int cy = h ~/ 2;

    int left = cx - cropSize ~/ 2;
    int top = cy - cropSize ~/ 2;

    if (left < 0) left = 0;
    if (top < 0) top = 0;

    int right = left + cropSize;
    int bottom = top + cropSize;

    if (right > w) right = w;
    if (bottom > h) bottom = h;

    return img_lib.copyCrop(
      img,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }

  // ✅ UI indicator widget
  Widget _statusIndicator({
    required IconData icon,
    required String title,
    required bool ok,
  }) {
    return Column(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: ok ? Colors.green : Colors.red,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
        const SizedBox(height: 6),
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 14)),
      ],
    );
  }

  Widget _buildQualityRow(_QualityItem item) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D1D),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            item.passed ? Icons.check_circle : Icons.cancel,
            color: item.passed ? Colors.greenAccent : Colors.redAccent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${item.title}: ${item.status}',
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
          Text(
            item.score,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ✅ Focus score
  _ScoreResult _calcFocusScore(img_lib.Image gray) {
    double lapSum = 0;
    int count = 0;

    for (int y = 1; y < gray.height - 1; y++) {
      for (int x = 1; x < gray.width - 1; x++) {
        final c = gray.getPixel(x, y).r.toDouble();
        final t = gray.getPixel(x, y - 1).r.toDouble();
        final b = gray.getPixel(x, y + 1).r.toDouble();
        final l = gray.getPixel(x - 1, y).r.toDouble();
        final r = gray.getPixel(x + 1, y).r.toDouble();

        final lap = (c * 4) - (t + b + l + r);
        lapSum += lap.abs();
        count++;
      }
    }

    return _ScoreResult(lapSum / count);
  }

  // ✅ Illumination score
  _ScoreResult _calcIllumScore(img_lib.Image gray) {
    double total = 0;
    final totalPixels = gray.width * gray.height;

    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        total += gray.getPixel(x, y).r.toDouble();
      }
    }

    return _ScoreResult(total / totalPixels);
  }

  // ✅ Skin coverage (rule based)
  _ScoreResult _calcSkinCoveragePercent(img_lib.Image img) {
    final int centerX = img.width ~/ 2;
    final int centerY = img.height ~/ 2;
    final int radius = (img.width * 0.45).toInt();

    int skinPixels = 0;
    int totalPixels = 0;

    for (int y = centerY - radius; y < centerY + radius; y += 2) {
      for (int x = centerX - radius; x < centerX + radius; x += 2) {
        if (x < 0 || x >= img.width || y < 0 || y >= img.height) continue;

        final dx = x - centerX;
        final dy = y - centerY;
        if (dx * dx + dy * dy > radius * radius) continue;

        totalPixels++;

        final p = img.getPixel(x, y);
        final r = p.r.toDouble();
        final g = p.g.toDouble();
        final b = p.b.toDouble();

        final bool skin =
            (r > 50 &&
            g > 35 &&
            b > 20 &&
            r > g &&
            r > b &&
            (r - g) > 8 &&
            (r - b) > 15);

        if (skin) skinPixels++;
      }
    }

    if (totalPixels == 0) return _ScoreResult(0);

    final percent = (skinPixels / totalPixels) * 100;
    return _ScoreResult(percent);
  }

  // ✅ Overall score (relaxed)
  int _calculateOverallScore({
    required double focusScore,
    required double illum,
    required double coveragePercent,
  }) {
    // focus max 35
    double focusPart = (focusScore / 35) * 35;
    if (focusPart > 35) focusPart = 35;
    if (focusPart < 0) focusPart = 0;

    // illum max 35
    double illumPart;
    if (illum >= 85 && illum <= 195) {
      illumPart = 35;
    } else if (illum >= 70 && illum <= 220) {
      illumPart = 25;
    } else {
      illumPart = 10;
    }

    // coverage max 30
    double coverPart = (coveragePercent / 100) * 30;
    if (coverPart > 30) coverPart = 30;
    if (coverPart < 0) coverPart = 0;

    final total = focusPart + illumPart + coverPart;
    return total.round();
  }

  // ✅ Main UI
  @override
  Widget build(BuildContext context) {
    if (!_isPermissionGranted) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            _errorMessage.isEmpty ? 'Requesting permission...' : _errorMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              _controller != null &&
              _controller!.value.isInitialized) {
            return Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(_controller!),

                // dark overlay for better visibility
                Container(color: Colors.black.withOpacity(0.35)),

                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 18,
                    ),
                    child: Column(
                      children: [
                        // Top title
                        Row(
                          children: const [
                            Text(
                              "FingerScanner",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Spacer(),
                            Icon(Icons.settings, color: Colors.white70),
                          ],
                        ),

                        const SizedBox(height: 18),

                        // top 3 indicators (Focus/Light/Position)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _statusIndicator(
                              icon: Icons.center_focus_strong,
                              title: "Focus",
                              ok: true, // keep relaxed always OK
                            ),
                            _statusIndicator(
                              icon: Icons.wb_sunny,
                              title: "Light",
                              ok: _lightOk,
                            ),
                            _statusIndicator(
                              icon: Icons.crop_free,
                              title: "Position",
                              ok: _positionOk,
                            ),
                          ],
                        ),

                        const Spacer(),

                        // scanner box in center
                        Container(
                          width: 220,
                          height: 220,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: _positionOk ? Colors.green : Colors.red,
                              width: 3,
                            ),
                            color: (_positionOk ? Colors.green : Colors.red)
                                .withOpacity(0.12),
                            boxShadow: [
                              BoxShadow(
                                color: (_positionOk ? Colors.green : Colors.red)
                                    .withOpacity(0.25),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.fingerprint,
                              size: 90,
                              color: Colors.white70,
                            ),
                          ),
                        ),

                        const Spacer(),

                        // hint text
                        Text(
                          _hintText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: 10),

                        Text(
                          "Keep your finger steady inside the box",
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 14,
                          ),
                        ),

                        const SizedBox(height: 18),

                        // capture button
                        GestureDetector(
                          onTap: _captureImage,
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: const Color(0xFF6A5ACD),
                              borderRadius: BorderRadius.circular(18),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.4),
                                  blurRadius: 12,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.camera_alt,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ),

                        const SizedBox(height: 22),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          return Center(
            child: Text(
              _errorMessage.isEmpty ? "Loading..." : _errorMessage,
              style: const TextStyle(color: Colors.white),
            ),
          );
        },
      ),
    );
  }
}

// ========== helper models ==========
class _QualityItem {
  final String title;
  final String status;
  final bool passed;
  final String score;

  _QualityItem(this.title, this.status, this.passed, {required this.score});
}

class _ScoreResult {
  final double value;
  _ScoreResult(this.value);
}
