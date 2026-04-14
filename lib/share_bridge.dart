import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'repost_service.dart';

class ShareBridge {
  static const _channel = MethodChannel('reposter/share');

  Future<void> shareToPlatform({
    required SocialPlatform platform,
    required String filePath,
    required String caption,
  }) async {
    if (kDebugMode) print('[Share] Sharing ${platform.label} video: $filePath');
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _shareOnAndroid(
        platform: platform,
        filePath: filePath,
        caption: caption,
      );
      return;
    }

    await Share.shareXFiles(
      [XFile(filePath)],
      text: caption,
    );
  }

  Future<void> _shareOnAndroid({
    required SocialPlatform platform,
    required String filePath,
    required String caption,
  }) async {
    final packages = switch (platform) {
      SocialPlatform.instagram => const ['com.instagram.android'],
      SocialPlatform.tiktok => const [
        'com.zhiliaoapp.musically',
        'com.ss.android.ugc.trill',
      ],
    };

    PlatformException? lastError;

    for (final packageName in packages) {
      try {
        await _channel.invokeMethod<void>('shareToTarget', {
          'filePath': filePath,
          'packageName': packageName,
          'caption': caption,
        });
        return;
      } on PlatformException catch (error) {
        lastError = error;
        if (error.code != 'APP_NOT_FOUND') {
          rethrow;
        }
      }
    }

    throw lastError ??
        PlatformException(
          code: 'APP_NOT_FOUND',
          message: 'Install the target app first.',
        );
  }

  Future<void> shareGeneric({
    required String filePath,
    required String caption,
  }) async {
    await Share.shareXFiles(
      [XFile(filePath)],
      text: caption,
    );
  }

  bool get supportsDirectAppShare => !kIsWeb && Platform.isAndroid;
}
