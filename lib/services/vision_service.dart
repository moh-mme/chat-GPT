import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// High level states for the text alignment helper.
enum AlignmentInstruction {
  centered,
  moveUp,
  moveDown,
  moveLeft,
  moveRight,
}

/// Holds the response of an object detection cycle.
class VisionResult {
  const VisionResult({required this.transcript, this.hasTargets = false});

  final String transcript;
  final bool hasTargets;
}

/// Bundles together object detection and OCR logic.
class VisionService {
  VisionService()
      : _objectDetector = ObjectDetector(options: _objectDetectorOptions),
        _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  final ObjectDetector _objectDetector;
  final TextRecognizer _textRecognizer;

  bool _detectingObjects = false;
  bool _guidingText = false;
  bool _busy = false;
  int _stableFrameCount = 0;

  static final LocalObjectDetectorOptions _objectDetectorOptions =
      LocalObjectDetectorOptions(
    mode: DetectionMode.stream,
    classifyObjects: true,
    multipleObjects: true,
  );

  /// Start processing the camera stream and perform continuous object
  /// recognition. The [onResult] callback is triggered with a natural language
  /// description that is ready to be spoken.
  Future<void> startObjectRecognition({
    required CameraController controller,
    required void Function(VisionResult) onResult,
  }) async {
    if (_detectingObjects || _guidingText) return;
    if (!controller.value.isStreamingImages) {
      await controller.startImageStream((CameraImage image) {
        _handleObjectFrame(
          image: image,
          camera: controller.description,
          onResult: onResult,
        );
      });
    }
    _detectingObjects = true;
  }

  Future<void> stopObjectRecognition(CameraController controller) async {
    if (!_detectingObjects) return;
    _detectingObjects = false;
    if (controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
  }

  Future<void> startTextGuidance({
    required CameraController controller,
    required void Function(String) onInstruction,
    required void Function(String) onTextReady,
  }) async {
    if (_guidingText) return;
    await stopObjectRecognition(controller);
    if (!controller.value.isStreamingImages) {
      await controller.startImageStream((CameraImage image) {
        _handleTextFrame(
          image: image,
          controller: controller,
          onInstruction: onInstruction,
          onTextReady: onTextReady,
        );
      });
    }
    _guidingText = true;
    _stableFrameCount = 0;
  }

  Future<void> stopTextGuidance(CameraController controller) async {
    if (!_guidingText) return;
    _guidingText = false;
    _stableFrameCount = 0;
    if (controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
  }

  Future<void> dispose() async {
    await _objectDetector.close();
    await _textRecognizer.close();
  }

  Future<void> _handleObjectFrame({
    required CameraImage image,
    required CameraDescription camera,
    required void Function(VisionResult) onResult,
  }) async {
    if (!_detectingObjects || _busy) return;
    _busy = true;
    try {
      final inputImage = _cameraImageToInputImage(image, camera.sensorOrientation);
      final detections = await _objectDetector.processImage(inputImage);
      final imageSize = inputImage.metadata?.size;
      if (detections.isEmpty) {
        onResult(const VisionResult(transcript: 'لا أرى شيئًا محددًا أمامك.'));
      } else {
        final description = detections
            .map((detection) =>
                _detectedObjectToSpeech(detection, imageSize?.width ?? 0))
            .join('، ');
        onResult(VisionResult(
          transcript: description,
          hasTargets: detections.isNotEmpty,
        ));
      }
    } catch (error, stack) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('Object detection error: $error -> $stack');
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _handleTextFrame({
    required CameraImage image,
    required CameraController controller,
    required void Function(String) onInstruction,
    required void Function(String) onTextReady,
  }) async {
    if (!_guidingText || _busy) return;
    _busy = true;
    try {
      final instruction = _calculateAlignmentHint(image);
      if (instruction == AlignmentInstruction.centered) {
        _stableFrameCount++;
        if (_stableFrameCount > 4) {
          onInstruction('ثابت الآن، سألتقط النص.');
          await controller.stopImageStream();
          final file = await controller.takePicture();
          final inputImage = InputImage.fromFilePath(file.path);
          final recognisedText = await _textRecognizer.processImage(inputImage);
          final text = recognisedText.text.trim().isEmpty
              ? 'لم أتمكن من قراءة النص.'
              : recognisedText.text;
          onTextReady(text);
          _guidingText = false;
          _stableFrameCount = 0;
        } else {
          onInstruction('أحسنت، ابقَ ثابتًا.');
        }
      } else {
        _stableFrameCount = 0;
        onInstruction(_instructionToSpeech(instruction));
      }
    } catch (error, stack) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('Text guidance error: $error -> $stack');
      }
    } finally {
      _busy = false;
    }
  }

  String _detectedObjectToSpeech(DetectedObject detection, double imageWidth) {
    final label = detection.labels.isNotEmpty
        ? detection.labels
            .map((label) => label.text)
            .take(2)
            .join(' ')
        : 'عنصر';
    final position = detection.boundingBox.center;
    final width = imageWidth <= 0 ? detection.boundingBox.width * 3 : imageWidth;
    final horizontal = position.dx / width;
    final zone = horizontal < 0.33
        ? 'على يسارك'
        : horizontal > 0.66
            ? 'على يمينك'
            : 'أمامك';
    return '$label $zone';
  }

  AlignmentInstruction _calculateAlignmentHint(CameraImage image) {
    final plane = image.planes.first;
    final bytes = plane.bytes;
    final width = image.width;
    final height = image.height;
    final bytesPerRow = plane.bytesPerRow;

    double topSum = 0;
    double bottomSum = 0;
    double leftSum = 0;
    double rightSum = 0;

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final index = y * bytesPerRow + x;
        if (index >= bytes.length) continue;
        final value = bytes[index];
        if (y < height / 2) {
          topSum += value;
        } else {
          bottomSum += value;
        }
        if (x < width / 2) {
          leftSum += value;
        } else {
          rightSum += value;
        }
      }
    }

    final verticalDiff = (topSum - bottomSum).abs() / math.max(1, bottomSum);
    if (verticalDiff > 0.15) {
      return topSum < bottomSum
          ? AlignmentInstruction.moveUp
          : AlignmentInstruction.moveDown;
    }

    final horizontalDiff = (leftSum - rightSum).abs() / math.max(1, rightSum);
    if (horizontalDiff > 0.15) {
      return leftSum < rightSum
          ? AlignmentInstruction.moveRight
          : AlignmentInstruction.moveLeft;
    }

    return AlignmentInstruction.centered;
  }

  String _instructionToSpeech(AlignmentInstruction instruction) {
    switch (instruction) {
      case AlignmentInstruction.moveUp:
        return 'حرّك الكاميرا إلى الأعلى قليلًا.';
      case AlignmentInstruction.moveDown:
        return 'حرّك الكاميرا إلى الأسفل قليلًا.';
      case AlignmentInstruction.moveLeft:
        return 'حرّك الكاميرا إلى اليسار.';
      case AlignmentInstruction.moveRight:
        return 'حرّك الكاميرا إلى اليمين.';
      case AlignmentInstruction.centered:
        return 'ثابت الآن، سألتقط النص قريبًا.';
    }
  }

  InputImage _cameraImageToInputImage(CameraImage image, int rotation) {
    final ui.WriteBuffer allBytes = ui.WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final Uint8List bytes = allBytes.done().buffer.asUint8List();

    final ui.Size imageSize =
        ui.Size(image.width.toDouble(), image.height.toDouble());
    final InputImageRotation imageRotation = InputImageRotationValue.fromRawValue(rotation) ?? InputImageRotation.rotation0deg;
    final InputImageFormat inputImageFormat = InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.nv21;

    final planeData = image.planes
        .map(
          (plane) => InputImagePlaneMetadata(
            bytesPerRow: plane.bytesPerRow,
            height: plane.height,
            width: plane.width,
          ),
        )
        .toList();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: planeData.first.bytesPerRow,
        planeData: planeData,
      ),
    );
  }
}
