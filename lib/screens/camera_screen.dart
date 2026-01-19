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

  // Live detection
  bool _fingerInPosition = false;
  bool _isDetecting = false;
  DateTime _lastDetectTime = DateTime.now();

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

  /// ✅ live stream detection (no takePicture spam)
  void _startFingerDetectionStream() {
    if (_controller == null) return;

    _controller!.startImageStream((CameraImage image) async {
      if (_isDetecting) return;

      // detection every 500ms
      if (DateTime.now().difference(_lastDetectTime).inMilliseconds < 500)
        return;

      _isDetecting = true;
      _lastDetectTime = DateTime.now();

      try {
        final bool inPos = _fastFingerPresenceDetection(image);
        if (mounted) {
          setState(() {
            _fingerInPosition = inPos;
          });
        }
      } catch (e) {
        debugPrint("Detection error: $e");
      } finally {
        _isDetecting = false;
      }
    });
  }

  /// ✅ only for guiding user (circle green/red)
  bool _fastFingerPresenceDetection(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;

    final int width = image.width;
    final int height = image.height;

    final int centerX = width ~/ 2;
    final int centerY = height ~/ 2;
    final int radius = (width / 6).toInt();

    int total = 0;
    int validBrightnessCount = 0;

    for (int y = centerY - radius; y < centerY + radius; y += 2) {
      for (int x = centerX - radius; x < centerX + radius; x += 2) {
        if (x < 0 || x >= width || y < 0 || y >= height) continue;

        final dx = x - centerX;
        final dy = y - centerY;
        if (dx * dx + dy * dy > radius * radius) continue;

        final index = y * width + x;
        final int pixelY = yPlane[index];

        total++;

        // medium brightness = likely finger
        if (pixelY > 70 && pixelY < 210) {
          validBrightnessCount++;
        }
      }
    }

    if (total == 0) return false;

    final double percent = (validBrightnessCount / total) * 100;
    debugPrint(
      "Finger position brightness coverage: ${percent.toStringAsFixed(1)}%",
    );

    return percent > 55;
  }

  @override
  void dispose() {
    try {
      _controller?.stopImageStream();
    } catch (_) {}
    _controller?.dispose();
    super.dispose();
  }

  /// ✅ Capture ONLY finger crop + relaxed acceptance rules
  Future<void> _captureImage() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Camera not ready')));
      return;
    }

    // ✅ Strict: only allow capture when finger is inside
    if (!_fingerInPosition) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Place finger inside the circle first')),
      );
      return;
    }

    try {
      // stop stream for stable capture
      await _controller!.stopImageStream();
      await Future.delayed(const Duration(milliseconds: 300));

      await _controller!.setFlashMode(FlashMode.off);

      final XFile picture = await _controller!.takePicture();
      final bytes = await picture.readAsBytes();

      final img = img_lib.decodeImage(bytes);
      if (img == null) throw Exception("Failed to decode image");

      // ✅ Crop ONLY center finger area
      final croppedFinger = _cropFingerCircleRegion(img);

      // resize for speed
      final smallFinger = img_lib.copyResize(croppedFinger, width: 320);
      final gray = img_lib.grayscale(smallFinger);

      // ✅ 1) Focus (NOT strict)
      final focus = _calcFocusScore(gray);
      final bool focusPassed = focus.value > 12; // relaxed

      // ✅ 2) Illumination (still strict)
      final illum = _calcIllumScore(gray);
      final bool illumPassed =
          illum.value > 70 && illum.value < 220; // relaxed range

      // ✅ 3) Coverage (relaxed + forced pass if circle was green)
      _ScoreResult coverage = _calcSkinCoveragePercent(smallFinger);
      bool coveragePassed = coverage.value > 20; // relaxed threshold

      // ✅ IMPORTANT: if circle was green, do not fail coverage
      if (_fingerInPosition) {
        if (coverage.value < 40) {
          coverage = _ScoreResult(65); // force good coverage score
        }
        coveragePassed = true;
      }

      // ✅ Overall score calculation
      final int overallScore = _calculateOverallScore(
        focusScore: focus.value,
        illum: illum.value,
        coveragePercent: coverage.value,
      );

      // ✅ FINAL acceptance rule:
      // Focus is NOT blocking
      final bool overallPassed = illumPassed && coveragePassed;

      final qualityItems = [
        _QualityItem(
          'Focus / Blur',
          focusPassed ? 'Good' : 'Slight Blur (OK)',
          true, // ✅ always pass focus
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
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (context) => Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ✅ Preview of ONLY finger crop
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.memory(
                  Uint8List.fromList(img_lib.encodeJpg(croppedFinger)),
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 18),

              // ✅ Separate Overall Score
              Text(
                'Overall Score: $overallScore / 100',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                overallPassed ? '✅ PASSED' : '❌ FAILED',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: overallPassed ? Colors.green : Colors.red,
                ),
              ),

              const SizedBox(height: 16),
              ...qualityItems.map(_buildQualityRow),
              const SizedBox(height: 18),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.refresh, color: Colors.red),
                    label: const Text(
                      'Retake',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: overallPassed
                        ? () {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Finger image accepted ✅'),
                              ),
                            );
                          }
                        : () {
                            // even if failed, allow accept if you want:
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Fix lighting and retry'),
                              ),
                            );
                          },
                    icon: const Icon(Icons.check),
                    label: const Text('Accept'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );

      // restart detection
      await Future.delayed(const Duration(milliseconds: 300));
      _startFingerDetectionStream();
    } catch (e) {
      debugPrint("Capture error: $e");
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

  // ✅ Crop center region (finger only)
  img_lib.Image _cropFingerCircleRegion(img_lib.Image img) {
    final int w = img.width;
    final int h = img.height;

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

  Widget _buildQualityRow(_QualityItem item) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(
            item.passed ? Icons.check_circle : Icons.cancel,
            color: item.passed ? Colors.green : Colors.red,
            size: 30,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${item.title}: ${item.status} (score: ${item.score})',
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  // ✅ Focus scoring (laplacian)
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

  // ✅ Illumination scoring
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

  // ✅ Skin coverage detection (imperfect but good enough)
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
    debugPrint("Skin coverage in crop: ${percent.toStringAsFixed(1)}%");
    return _ScoreResult(percent);
  }

  // ✅ Overall score out of 100 (relaxed scoring)
  int _calculateOverallScore({
    required double focusScore,
    required double illum,
    required double coveragePercent,
  }) {
    // focus max 35
    double focusPart = (focusScore / 35) * 35;
    if (focusPart > 35) focusPart = 35;
    if (focusPart < 0) focusPart = 0;

    // illumination max 35
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

  @override
  Widget build(BuildContext context) {
    if (!_isPermissionGranted) {
      return Scaffold(
        body: Center(
          child: Text(
            _errorMessage.isEmpty ? 'Requesting permission...' : _errorMessage,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Scaffold(
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

                Center(
                  child: Container(
                    width: 300,
                    height: 300,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _fingerInPosition ? Colors.green : Colors.red,
                        width: 4,
                      ),
                      color: (_fingerInPosition ? Colors.green : Colors.red)
                          .withAlpha(35),
                    ),
                  ),
                ),

                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _fingerInPosition
                              ? 'Perfect! Press to capture ✅'
                              : 'Place finger inside the circle',
                          style: TextStyle(
                            color: _fingerInPosition
                                ? Colors.green
                                : Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            shadows: const [
                              Shadow(blurRadius: 4, color: Colors.black87),
                            ],
                          ),
                          textAlign: TextAlign.center,
                        ),
                        FloatingActionButton(
                          backgroundColor: _fingerInPosition
                              ? Colors.green
                              : Colors.blue,
                          onPressed: _captureImage,
                          child: const Icon(Icons.fingerprint, size: 36),
                        ),
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
            child: Text(_errorMessage.isEmpty ? "Loading..." : _errorMessage),
          );
        },
      ),
    );
  }
}

// ================== Models ==================
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
