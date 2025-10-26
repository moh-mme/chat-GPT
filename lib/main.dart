import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'services/stt_service.dart';
import 'services/tts_service.dart';
import 'services/vision_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final primaryCamera = cameras.isNotEmpty ? cameras.first : null;
  runApp(
    ChangeNotifierProvider(
      create: (_) => BasirAppState(primaryCamera),
      child: const BasirApp(),
    ),
  );
}

class BasirApp extends StatelessWidget {
  const BasirApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Basir',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        textTheme: Theme.of(context).textTheme.apply(
              fontFamily: 'Roboto',
              bodyColor: Colors.white,
              displayColor: Colors.white,
            ),
      ),
      debugShowCheckedModeBanner: false,
      home: const HomeScreen(),
    );
  }
}

class BasirAppState extends ChangeNotifier {
  BasirAppState(CameraDescription? cameraDescription)
      : _cameraDescription = cameraDescription,
        ttsService = TtsService(),
        sttService = SttService(),
        visionService = VisionService();

  final CameraDescription? _cameraDescription;
  final TtsService ttsService;
  final SttService sttService;
  final VisionService visionService;

  CameraController? _cameraController;
  CameraController? get cameraController => _cameraController;

  bool _initialised = false;
  bool get isInitialised => _initialised;

  bool _isListening = false;
  bool get isListening => _isListening;

  bool _isRecognising = false;
  bool get isRecognising => _isRecognising;

  bool _isReadingText = false;
  bool get isReadingText => _isReadingText;

  String _statusMessage = 'اضغط على الزر لبدء التفاعل.';
  String get statusMessage => _statusMessage;

  String _lastVisionMessage = '';
  String get lastVisionMessage => _lastVisionMessage;

  DateTime _lastVisionSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastGuidanceMessage = '';

  Future<void> initialise() async {
    if (_initialised) return;
    if (_cameraDescription == null) {
      _statusMessage = 'لم يتم العثور على كاميرا على هذا الجهاز.';
      await ttsService.speak(_statusMessage);
      notifyListeners();
      return;
    }
    _cameraController = CameraController(
      _cameraDescription!,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    try {
      await _cameraController!.initialize();
      await ttsService.init();
      await sttService.init();
      _initialised = true;
      _statusMessage = 'مرحبًا، أنا بصير. قل "ابدأ التعرف" للبدء.';
      await ttsService.speak(_statusMessage);
    } on CameraException catch (error) {
      _statusMessage = 'تعذر تهيئة الكاميرا: ${error.description}';
      await ttsService.speak(_statusMessage);
    }
    notifyListeners();
  }

  Future<void> toggleListening() async {
    if (!isInitialised) {
      await initialise();
      return;
    }
    if (_isListening) {
      await sttService.stop();
      _isListening = false;
      notifyListeners();
      return;
    }
    _isListening = true;
    _statusMessage = 'أستمع الآن...';
    notifyListeners();
    await ttsService.speak('تفضل، أنا أستمع.');
    await sttService.listen(onCommand: (command) {
      _isListening = false;
      notifyListeners();
      if (command.isEmpty) {
        _statusMessage = 'لم أفهم. حاول مرة أخرى.';
        ttsService.speak(_statusMessage);
      } else {
        handleCommand(command);
      }
    });
  }

  Future<void> handleCommand(String command) async {
    final cleaned = command.toLowerCase().trim();
    if (cleaned.isEmpty) return;

    if (_containsAny(cleaned, ['إيقاف', 'قف', 'توقف', 'stop'])) {
      await stopAllActivities();
      return;
    }

    if (_containsAny(cleaned, ['ابدأ التعرف', 'تشغيل التعرف', 'start recognition'])) {
      await startContinuousRecognition();
      return;
    }

    if (_containsAny(cleaned, ['اقرأ النص', 'قراءة النص', 'read text'])) {
      await startTextReading();
      return;
    }

    _statusMessage = 'الأمر غير معروف: $command';
    notifyListeners();
    await ttsService.speak('لم أفهم الأمر. حاول قول ابدأ التعرف أو اقرأ النص.');
  }

  Future<void> startContinuousRecognition() async {
    if (_cameraController == null) return;
    await stopTextReading();
    if (_isRecognising) {
      await ttsService.speak('وضع التعرف يعمل بالفعل.');
      return;
    }
    _isRecognising = true;
    _statusMessage = 'التعرف على العناصر مستمر.';
    notifyListeners();
    await ttsService.speak('بدأت التعرف على العناصر من حولك.');
    await visionService.startObjectRecognition(
      controller: _cameraController!,
      onResult: (VisionResult result) async {
        _lastVisionMessage = result.transcript;
        _statusMessage = result.transcript;
        notifyListeners();
        final now = DateTime.now();
        final shouldSpeak =
            result.hasTargets || now.difference(_lastVisionSpoken).inSeconds > 4;
        if (shouldSpeak) {
          _lastVisionSpoken = now;
          await ttsService.speak(result.transcript);
        }
      },
    );
  }

  Future<void> stopContinuousRecognition() async {
    if (_cameraController == null || !_isRecognising) return;
    await visionService.stopObjectRecognition(_cameraController!);
    _isRecognising = false;
    _statusMessage = 'تم إيقاف وضع التعرف.';
    notifyListeners();
    await ttsService.speak('أوقفت التعرف.');
  }

  Future<void> startTextReading() async {
    if (_cameraController == null) return;
    await stopContinuousRecognition();
    if (_isReadingText) {
      await ttsService.speak('أنا أجهز النص بالفعل.');
      return;
    }
    _isReadingText = true;
    _statusMessage = 'تجهيز قراءة النص.';
    notifyListeners();
    await ttsService.speak('افتح النص أمام الكاميرا. سأساعدك في ضبطه.');
    await visionService.startTextGuidance(
      controller: _cameraController!,
      onInstruction: (instruction) async {
        if (instruction != _lastGuidanceMessage) {
          _lastGuidanceMessage = instruction;
          _statusMessage = instruction;
          notifyListeners();
          await ttsService.speak(instruction);
        }
      },
      onTextReady: (text) async {
        _isReadingText = false;
        _lastGuidanceMessage = '';
        _statusMessage = 'قراءة النص.';
        notifyListeners();
        await ttsService.speak('النص يقول: $text');
      },
    );
  }

  Future<void> stopTextReading() async {
    if (_cameraController == null || !_isReadingText) return;
    await visionService.stopTextGuidance(_cameraController!);
    _isReadingText = false;
    _statusMessage = 'تم إيقاف قراءة النص.';
    notifyListeners();
    await ttsService.speak('أوقفت قراءة النص.');
  }

  Future<void> stopAllActivities() async {
    await stopContinuousRecognition();
    await stopTextReading();
    await sttService.stop();
    _statusMessage = 'تم الإيقاف. قل "ابدأ التعرف" للمتابعة.';
    notifyListeners();
    await ttsService.speak('تم إيقاف كل شيء.');
  }

  Future<void> toggleLanguage() async {
    if (ttsService.currentLanguage == 'ar-SA') {
      await ttsService.setLanguage('en-US');
      await ttsService.speak('Switched to English.');
    } else {
      await ttsService.setLanguage('ar-SA');
      await ttsService.speak('عدت إلى العربية.');
    }
  }

  @override
  Future<void> dispose() async {
    await ttsService.dispose();
    await sttService.stop();
    await visionService.dispose();
    await _cameraController?.dispose();
    super.dispose();
  }

  bool _containsAny(String command, List<String> options) {
    for (final option in options) {
      if (command.contains(option.toLowerCase())) {
        return true;
      }
    }
    return false;
  }
}
