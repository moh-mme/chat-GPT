import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// A helper that exposes the speech-to-text functionality with sensible
/// defaults for Arabic recognition.
class SttService {
  SttService();

  final SpeechToText _speech = SpeechToText();
  bool _initialised = false;
  bool get isListening => _speech.isListening;

  Future<bool> init() async {
    if (_initialised) return true;
    final available = await _speech.initialize(
      onStatus: _onStatus,
      onError: _onError,
      debugLogging: kDebugMode,
    );
    _initialised = available;
    return available;
  }

  /// Listen for a single command and return the text via the provided
  /// callback. The recogniser automatically stops once a result with sufficient
  /// confidence is produced.
  Future<void> listen({
    required void Function(String) onCommand,
    String localeId = 'ar_SA',
  }) async {
    final ready = await init();
    if (!ready) {
      onCommand('');
      return;
    }
    await _speech.listen(
      localeId: localeId,
      listenFor: const Duration(seconds: 10),
      pauseFor: const Duration(seconds: 3),
      partialResults: false,
      onResult: (SpeechRecognitionResult result) {
        if (result.recognizedWords.isNotEmpty) {
          onCommand(result.recognizedWords.toLowerCase());
        }
      },
      onSoundLevelChange: null,
      cancelOnError: true,
    );
  }

  Future<void> stop() async {
    await _speech.stop();
  }

  void _onStatus(String status) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('Speech status: $status');
    }
  }

  void _onError(SpeechRecognitionError error) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('Speech error: $error');
    }
  }
}
