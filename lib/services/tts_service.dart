import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// A thin wrapper around [FlutterTts] that centralises the speech
/// configuration for the application.
class TtsService {
  TtsService();

  final FlutterTts _flutterTts = FlutterTts();
  bool _initialised = false;
  String _currentLanguage = 'ar-SA';

  /// Initialise the TTS engine with Arabic as the default language and a
  /// comfortable speaking rate for accessibility.
  Future<void> init() async {
    if (_initialised) return;
    await _flutterTts.awaitSpeakCompletion(true);
    await setLanguage('ar-SA');
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
    _initialised = true;
  }

  /// Switch between Arabic and English voices.
  Future<void> setLanguage(String languageCode) async {
    _currentLanguage = languageCode;
    await _flutterTts.setLanguage(languageCode);
  }

  String get currentLanguage => _currentLanguage;

  /// Speak a sentence out loud. The method ensures that the speech engine is
  /// initialised before attempting to speak.
  Future<void> speak(String message) async {
    if (message.isEmpty) return;
    await init();
    try {
      await _flutterTts.stop();
      await _flutterTts.speak(message);
      await HapticFeedback.selectionClick();
    } catch (err, stackTrace) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('TTS error: $err -> $stackTrace');
      }
    }
  }

  /// Stop any speech currently playing.
  Future<void> stop() async {
    await _flutterTts.stop();
  }

  Future<void> dispose() async {
    await _flutterTts.stop();
    await _flutterTts.awaitSpeakCompletion(false);
  }
}
