import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as VegasHunterMath;
import 'dart:ui';

import 'package:appsflyer_sdk/appsflyer_sdk.dart'
    show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, SystemUiOverlayStyle, SystemChrome;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as VegasHunterTimezoneData;
import 'package:timezone/timezone.dart' as VegasHunterTimezone;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// Если эти классы есть в main.dart – оставь импорт.
import 'main.dart' show MafiaHarbor, CaptainHarbor, BillHarbor;

// ============================================================================
// VegasHunter инфраструктура (бывшая Dress Retro инфраструктура / Ncup)
// ============================================================================

class VegasHunterLogger {
  const VegasHunterLogger();

  void vegasHunterLogInfo(Object vegasHunterMessage) =>
      debugPrint('[DressRetroLogger] $vegasHunterMessage');

  void vegasHunterLogWarn(Object vegasHunterMessage) =>
      debugPrint('[DressRetroLogger/WARN] $vegasHunterMessage');

  void vegasHunterLogError(Object vegasHunterMessage) =>
      debugPrint('[DressRetroLogger/ERR] $vegasHunterMessage');
}

class VegasHunterVault {
  static final VegasHunterVault sharedInstance =
  VegasHunterVault._internalConstructor();
  VegasHunterVault._internalConstructor();
  factory VegasHunterVault() => sharedInstance;

  final VegasHunterLogger vegasHunterLoggerInstance =
  const VegasHunterLogger();
}

// ============================================================================
// Константы (статистика/кеш) — строки в кавычках не меняем
// ============================================================================

const String vegasHunterMetrLoadedOnceKey = 'wheel_loaded_once';
const String vegasHunterMetrStatEndpoint =
    'https://getgame.portalroullete.bar/stat';
const String vegasHunterMetrCachedFcmKey = 'wheel_cached_fcm';

// НОВОЕ: ключи для сохранения SafeArea и цвета в SharedPreferences
const String vegasHunterSafeAreaEnabledKey = 'safearea_enabled';
const String vegasHunterSafeAreaColorKey = 'safearea_color';

// ---------------- Bank constants (из первого main.dart) ----------------

const Set<String> vegasHunterBankSchemes = {
  'td',
  'rbc',
  'cibc',
  'scotiabank',
  'bmo',
  'bmodigitalbanking',
  'desjardins',
  'tangerine',
  'nationalbank',
  'simplii',
  'dominotoronto',
};

const Set<String> vegasHunterBankDomains = {
  'td.com',
  'tdcanadatrust.com',
  'easyweb.td.com',
  'rbc.com',
  'royalbank.com',
  'online.royalbank.com',
  'cibc.com',
  'cibc.ca',
  'online.cibc.com',
  'scotiabank.com',
  'scotiaonline.scotiabank.com',
  'bmo.com',
  'bmo.ca',
  'bmodigitalbanking.com',
  'desjardins.com',
  'tangerine.ca',
  'nbc.ca',
  'nationalbank.ca',
  'simplii.com',
  'simplii.ca',
  'dominotoronto.com',
  'dominobank.com',
};

// ============================================================================
// Утилиты: VegasHunterKit (бывший DressRetroKit / NcupKit)
// ============================================================================

class VegasHunterKit {
  static bool vegasHunterLooksLikeBareMail(Uri vegasHunterUri) {
    final String vegasHunterScheme = vegasHunterUri.scheme;
    if (vegasHunterScheme.isNotEmpty) return false;
    final String vegasHunterRaw = vegasHunterUri.toString();
    return vegasHunterRaw.contains('@') && !vegasHunterRaw.contains(' ');
  }

  static Uri vegasHunterToMailto(Uri vegasHunterUri) {
    final String vegasHunterFull = vegasHunterUri.toString();
    final List<String> vegasHunterBits = vegasHunterFull.split('?');
    final String vegasHunterWho = vegasHunterBits.first;
    final Map<String, String> vegasHunterQuery =
    vegasHunterBits.length > 1
        ? Uri.splitQueryString(vegasHunterBits[1])
        : <String, String>{};
    return Uri(
      scheme: 'mailto',
      path: vegasHunterWho,
      queryParameters: vegasHunterQuery.isEmpty ? null : vegasHunterQuery,
    );
  }

  static Uri vegasHunterGmailize(Uri vegasHunterMailUri) {
    final Map<String, String> vegasHunterQp =
        vegasHunterMailUri.queryParameters;
    final Map<String, String> vegasHunterParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (vegasHunterMailUri.path.isNotEmpty) 'to': vegasHunterMailUri.path,
      if ((vegasHunterQp['subject'] ?? '').isNotEmpty)
        'su': vegasHunterQp['subject']!,
      if ((vegasHunterQp['body'] ?? '').isNotEmpty)
        'body': vegasHunterQp['body']!,
      if ((vegasHunterQp['cc'] ?? '').isNotEmpty) 'cc': vegasHunterQp['cc']!,
      if ((vegasHunterQp['bcc'] ?? '').isNotEmpty)
        'bcc': vegasHunterQp['bcc']!,
    };
    return Uri.https('mail.google.com', '/mail/', vegasHunterParams);
  }

  static String vegasHunterDigitsOnly(String vegasHunterSource) =>
      vegasHunterSource.replaceAll(RegExp(r'[^0-9+]'), '');
}

// ============================================================================
// Сервис открытия ссылок: VegasHunterLinker (бывший DressRetroLinker / NcupLinker)
// ============================================================================

class VegasHunterLinker {
  static Future<bool> vegasHunterOpen(Uri vegasHunterUri) async {
    try {
      if (await launchUrl(
        vegasHunterUri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }
      return await launchUrl(
        vegasHunterUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (vegasHunterError) {
      debugPrint('DressRetroLinker error: $vegasHunterError; url=$vegasHunterUri');
      try {
        return await launchUrl(
          vegasHunterUri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }
}

// ============================================================================
// Bank helpers (из первого main.dart)
// ============================================================================

bool vegasHunterIsBankScheme(Uri vegasHunterUri) {
  final String vegasHunterScheme = vegasHunterUri.scheme.toLowerCase();
  return vegasHunterBankSchemes.contains(vegasHunterScheme);
}

bool vegasHunterIsBankDomain(Uri vegasHunterUri) {
  final String vegasHunterHost = vegasHunterUri.host.toLowerCase();
  if (vegasHunterHost.isEmpty) return false;

  for (final String vegasHunterBank in vegasHunterBankDomains) {
    final String vegasHunterBankHost = vegasHunterBank.toLowerCase();
    if (vegasHunterHost == vegasHunterBankHost ||
        vegasHunterHost.endsWith('.$vegasHunterBankHost')) {
      return true;
    }
  }
  return false;
}

Future<bool> vegasHunterOpenBank(Uri vegasHunterUri) async {
  try {
    if (vegasHunterIsBankScheme(vegasHunterUri)) {
      final bool vegasHunterOk = await launchUrl(
        vegasHunterUri,
        mode: LaunchMode.externalApplication,
      );
      return vegasHunterOk;
    }

    if ((vegasHunterUri.scheme == 'http' || vegasHunterUri.scheme == 'https') &&
        vegasHunterIsBankDomain(vegasHunterUri)) {
      final bool vegasHunterOk = await launchUrl(
        vegasHunterUri,
        mode: LaunchMode.externalApplication,
      );
      return vegasHunterOk;
    }
  } catch (vegasHunterError) {
    debugPrint('NcupOpenBank error: $vegasHunterError; url=$vegasHunterUri');
  }
  return false;
}

// ============================================================================
// FCM Background Handler
// ============================================================================

@pragma('vm:entry-point')
Future<void> vegasHunterFcmBackgroundHandler(
    RemoteMessage vegasHunterMessage) async {
  debugPrint("Spin ID: ${vegasHunterMessage.messageId}");
  debugPrint("Spin Data: ${vegasHunterMessage.data}");
}

// ============================================================================
// VegasHunterDeviceProfile (бывший DressRetroDeviceProfile / NcupDeviceProfile)
// ============================================================================

class VegasHunterDeviceProfile {
  String? vegasHunterDeviceId;
  String? vegasHunterSessionId = 'wheel-one-off';
  String? vegasHunterPlatformKind;
  String? vegasHunterOsBuild;
  String? vegasHunterAppVersion;
  String? vegasHunterLocaleCode;
  String? vegasHunterTimezoneName;
  bool vegasHunterPushEnabled = true;

  // Новый UA из WebView
  String? vegasHunterBaseUserAgent;

  // Для SafeArea
  bool vegasHunterSafeAreaEnabled = false;
  String? vegasHunterSafeAreaColor;

  Future<void> vegasHunterInitialize() async {
    try {
      VegasHunterTimezoneData.initializeTimeZones();
    } catch (_) {}

    final DeviceInfoPlugin vegasHunterInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo vegasHunterAndroidInfo =
      await vegasHunterInfoPlugin.androidInfo;
      vegasHunterDeviceId = vegasHunterAndroidInfo.id;
      vegasHunterPlatformKind = 'android';
      vegasHunterOsBuild = vegasHunterAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo vegasHunterIosInfo =
      await vegasHunterInfoPlugin.iosInfo;
      vegasHunterDeviceId = vegasHunterIosInfo.identifierForVendor;
      vegasHunterPlatformKind = 'ios';
      vegasHunterOsBuild = vegasHunterIosInfo.systemVersion;
    }

    final PackageInfo vegasHunterPackageInfo =
    await PackageInfo.fromPlatform();
    vegasHunterAppVersion = vegasHunterPackageInfo.version;
    vegasHunterLocaleCode = Platform.localeName.split('_').first;
    vegasHunterTimezoneName = VegasHunterTimezone.local.name;
    vegasHunterSessionId =
    'wheel-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> vegasHunterAsMap({String? vegasHunterFcmToken}) =>
      <String, dynamic>{
        'fcm_token': vegasHunterFcmToken ?? 'missing_token',
        'device_id': vegasHunterDeviceId ?? 'missing_id',
        'app_name': 'vegasday',
        'instance_id': vegasHunterSessionId ?? 'missing_session',
        'platform': vegasHunterPlatformKind ?? 'missing_system',
        'os_version': vegasHunterOsBuild ?? 'missing_build',
        'app_version': '1.4.1' ?? 'missing_app',
        'language': vegasHunterLocaleCode ?? 'en',
        'timezone': vegasHunterTimezoneName ?? 'UTC',
        'push_enabled': vegasHunterPushEnabled,
        'fthcashier': 'true',
        'safearea': vegasHunterSafeAreaEnabled,
        'safearea_color': vegasHunterSafeAreaColor ?? '',
        'base_ua': vegasHunterBaseUserAgent ?? '',
      };
}

// ============================================================================
// AppsFlyer шпион: VegasHunterSpy (бывший DressRetroSpy / NcupSpy)
// ============================================================================

class VegasHunterSpy {
  AppsFlyerOptions? vegasHunterOptions;
  AppsflyerSdk? vegasHunterSdk;

  String vegasHunterAppsFlyerUid = '';
  String vegasHunterAppsFlyerData = '';

  void vegasHunterStart({VoidCallback? vegasHunterOnUpdate}) {
    final AppsFlyerOptions vegasHunterOpts = AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6756072063',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    vegasHunterOptions = vegasHunterOpts;
    vegasHunterSdk = AppsflyerSdk(vegasHunterOpts);

    vegasHunterSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    vegasHunterSdk?.startSDK(
      onSuccess: () => VegasHunterVault()
          .vegasHunterLoggerInstance
          .vegasHunterLogInfo('WheelSpy started'),
      onError: (vegasHunterCode, vegasHunterMsg) => VegasHunterVault()
          .vegasHunterLoggerInstance
          .vegasHunterLogError(
          'WheelSpy error $vegasHunterCode: $vegasHunterMsg'),
    );

    vegasHunterSdk?.onInstallConversionData((vegasHunterValue) {
      vegasHunterAppsFlyerData = vegasHunterValue.toString();
      vegasHunterOnUpdate?.call();
    });

    vegasHunterSdk?.getAppsFlyerUID().then((vegasHunterValue) {
      vegasHunterAppsFlyerUid = vegasHunterValue.toString();
      vegasHunterOnUpdate?.call();
    });
  }
}

// ============================================================================
// Мост для FCM токена: VegasHunterFcmBridge (бывший DressRetroFcmBridge / NcupFcmBridge)
// ============================================================================

class VegasHunterFcmBridge {
  final VegasHunterLogger vegasHunterLog = const VegasHunterLogger();
  String? vegasHunterToken;
  final List<void Function(String)> vegasHunterWaiters =
  <void Function(String)>[];

  String? get vegasHunterCurrentToken => vegasHunterToken;

  VegasHunterFcmBridge() {
    const MethodChannel('com.example.fcm/token')
        .setMethodCallHandler((MethodCall vegasHunterCall) async {
      if (vegasHunterCall.method == 'setToken') {
        final String vegasHunterTokenString =
        vegasHunterCall.arguments as String;
        if (vegasHunterTokenString.isNotEmpty) {
          vegasHunterSetToken(vegasHunterTokenString);
        }
      }
    });

    vegasHunterRestoreToken();
  }

  Future<void> vegasHunterRestoreToken() async {
    try {
      final SharedPreferences vegasHunterPrefs =
      await SharedPreferences.getInstance();
      final String? vegasHunterCached =
      vegasHunterPrefs.getString(vegasHunterMetrCachedFcmKey);
      if (vegasHunterCached != null && vegasHunterCached.isNotEmpty) {
        vegasHunterSetToken(vegasHunterCached, vegasHunterNotify: false);
      }
    } catch (_) {}
  }

  Future<void> vegasHunterPersistToken(String vegasHunterNewToken) async {
    try {
      final SharedPreferences vegasHunterPrefs =
      await SharedPreferences.getInstance();
      await vegasHunterPrefs.setString(
          vegasHunterMetrCachedFcmKey, vegasHunterNewToken);
    } catch (_) {}
  }

  void vegasHunterSetToken(
      String vegasHunterNewToken, {
        bool vegasHunterNotify = true,
      }) {
    vegasHunterToken = vegasHunterNewToken;
    vegasHunterPersistToken(vegasHunterNewToken);
    if (vegasHunterNotify) {
      for (final void Function(String) vegasHunterCallback
      in List<void Function(String)>.from(vegasHunterWaiters)) {
        try {
          vegasHunterCallback(vegasHunterNewToken);
        } catch (vegasHunterErr) {
          vegasHunterLog
              .vegasHunterLogWarn('fcm waiter error: $vegasHunterErr');
        }
      }
      vegasHunterWaiters.clear();
    }
  }

  Future<void> vegasHunterWaitForToken(
      Function(String vegasHunterTokenValue) vegasHunterOnToken,
      ) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if ((vegasHunterToken ?? '').isNotEmpty) {
        vegasHunterOnToken(vegasHunterToken!);
        return;
      }

      vegasHunterWaiters.add(vegasHunterOnToken);
    } catch (vegasHunterErr) {
      vegasHunterLog
          .vegasHunterLogError('wheelWaitToken error: $vegasHunterErr');
    }
  }
}

// ============================================================================
// VegasHunterLoader (новый лоадер) (бывший NcupLoader)
// ============================================================================

class VegasHunterLoader extends StatefulWidget {
  const VegasHunterLoader({Key? key}) : super(key: key);

  @override
  State<VegasHunterLoader> createState() => _VegasHunterLoaderState();
}

class _VegasHunterLoaderState extends State<VegasHunterLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController vegasHunterController;

  static const Color vegasHunterBackgroundColor = Color(0xFF05071B);

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));
    vegasHunterController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    vegasHunterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: vegasHunterBackgroundColor,
      child: AnimatedBuilder(
        animation: vegasHunterController,
        builder: (BuildContext context, Widget? child) {
          final double vegasHunterPhase =
              vegasHunterController.value * 2 * VegasHunterMath.pi;
          return CustomPaint(
            painter: VegasHunterLoaderPainter(
              vegasHunterPhase: vegasHunterPhase,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class VegasHunterLoaderPainter extends CustomPainter {
  final double vegasHunterPhase;

  VegasHunterLoaderPainter({
    required this.vegasHunterPhase,
  });

  @override
  void paint(Canvas vegasHunterCanvas, Size vegasHunterSize) {
    final double vegasHunterWidth = vegasHunterSize.width;
    final double vegasHunterHeight = vegasHunterSize.height;

    final Paint vegasHunterBackgroundPaint = Paint()
      ..color = const Color(0xFF05071B)
      ..style = PaintingStyle.fill;
    vegasHunterCanvas.drawRect(
        Offset.zero & vegasHunterSize, vegasHunterBackgroundPaint);

    final double vegasHunterPulse =
        (VegasHunterMath.sin(vegasHunterPhase) + 1) / 2;

    final Paint vegasHunterCirclePaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.red.withOpacity(0.14 + 0.16 * vegasHunterPulse),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(vegasHunterWidth * 0.5, vegasHunterHeight * 0.45),
          radius: vegasHunterHeight * (0.4 + 0.15 * vegasHunterPulse),
        ),
      );

    vegasHunterCanvas.drawCircle(
      Offset(vegasHunterWidth * 0.5, vegasHunterHeight * 0.45),
      vegasHunterHeight * (0.4 + 0.15 * vegasHunterPulse),
      vegasHunterCirclePaint,
    );

    final Paint vegasHunterOuterPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.redAccent
              .withOpacity(0.10 + 0.10 * (1 - vegasHunterPulse)),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(vegasHunterWidth * 0.5, vegasHunterHeight * 0.45),
          radius: vegasHunterHeight * (0.55 + 0.10 * (1 - vegasHunterPulse)),
        ),
      );
    vegasHunterCanvas.drawCircle(
      Offset(vegasHunterWidth * 0.5, vegasHunterHeight * 0.45),
      vegasHunterHeight * (0.55 + 0.10 * (1 - vegasHunterPulse)),
      vegasHunterOuterPaint,
    );

    final double vegasHunterBaseSize = vegasHunterWidth * 0.35;
    final double vegasHunterFontSize =
        vegasHunterBaseSize + vegasHunterPulse * (vegasHunterBaseSize * 0.15);

    const String vegasHunterLetter = 'N';
    const String vegasHunterWord = 'CUP';

    final TextPainter vegasHunterLetterPainter = TextPainter(
      text: TextSpan(
        text: vegasHunterLetter,
        style: TextStyle(
          fontSize: vegasHunterFontSize,
          fontWeight: FontWeight.w900,
          color: Colors.red.shade600,
          letterSpacing: 4,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.8),
              blurRadius: 22 + 18 * vegasHunterPulse,
              offset: const Offset(0, 0),
            ),
            Shadow(
              color: Colors.black.withOpacity(0.8),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: vegasHunterWidth);

    final double vegasHunterLetterX =
        (vegasHunterWidth - vegasHunterLetterPainter.width) / 2;
    final double vegasHunterLetterY =
        (vegasHunterHeight - vegasHunterLetterPainter.height) / 2;

    final Offset vegasHunterLetterOffset =
    Offset(vegasHunterLetterX, vegasHunterLetterY);

    final Rect vegasHunterLetterRect = Rect.fromCenter(
      center: Offset(vegasHunterWidth / 2, vegasHunterHeight / 2),
      width: vegasHunterLetterPainter.width * 1.4,
      height: vegasHunterLetterPainter.height * 1.6,
    );

    final Paint vegasHunterGlowPaint = Paint()
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        28 + 24 * vegasHunterPulse,
      )
      ..color = Colors.red.withOpacity(0.7 + 0.2 * vegasHunterPulse);

    vegasHunterCanvas.saveLayer(vegasHunterLetterRect, vegasHunterGlowPaint);
    vegasHunterLetterPainter.paint(vegasHunterCanvas, vegasHunterLetterOffset);
    vegasHunterCanvas.restore();

    vegasHunterLetterPainter.paint(vegasHunterCanvas, vegasHunterLetterOffset);

    final double vegasHunterCupFontSize = vegasHunterWidth * 0.11;

    final TextPainter vegasHunterCupPainterReal = TextPainter(
      text: TextSpan(
        text: vegasHunterWord,
        style: TextStyle(
          fontSize: vegasHunterCupFontSize,
          fontWeight: FontWeight.w600,
          color: Colors.red.shade100.withOpacity(0.95),
          letterSpacing: 5,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.7),
              blurRadius: 12 + 10 * vegasHunterPulse,
              offset: const Offset(0, 0),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: vegasHunterWidth);

    final double vegasHunterCupX =
        (vegasHunterWidth - vegasHunterCupPainterReal.width) / 2;
    final double vegasHunterCupY =
        vegasHunterLetterY + vegasHunterLetterPainter.height +
            vegasHunterHeight * 0.03;

    final Offset vegasHunterCupOffset = Offset(vegasHunterCupX, vegasHunterCupY);
    vegasHunterCupPainterReal.paint(vegasHunterCanvas, vegasHunterCupOffset);
  }

  @override
  bool shouldRepaint(
      covariant VegasHunterLoaderPainter vegasHunterOldDelegate) =>
      vegasHunterOldDelegate.vegasHunterPhase != vegasHunterPhase;
}

// ============================================================================
// Статистика (VegasHunterFinalUrl / VegasHunterPostStat) — строки не меняем
// ============================================================================

Future<String> vegasHunterFinalUrl(
    String vegasHunterStartUrl, {
      int vegasHunterMaxHops = 10,
    }) async {
  final HttpClient vegasHunterClient = HttpClient();

  try {
    Uri vegasHunterCurrentUri = Uri.parse(vegasHunterStartUrl);

    for (int vegasHunterIndex = 0;
    vegasHunterIndex < vegasHunterMaxHops;
    vegasHunterIndex++) {
      final HttpClientRequest vegasHunterRequest =
      await vegasHunterClient.getUrl(vegasHunterCurrentUri);
      vegasHunterRequest.followRedirects = false;
      final HttpClientResponse vegasHunterResponse =
      await vegasHunterRequest.close();

      if (vegasHunterResponse.isRedirect) {
        final String? vegasHunterLocation = vegasHunterResponse.headers
            .value(HttpHeaders.locationHeader);
        if (vegasHunterLocation == null || vegasHunterLocation.isEmpty) break;

        final Uri vegasHunterNextUri = Uri.parse(vegasHunterLocation);
        vegasHunterCurrentUri = vegasHunterNextUri.hasScheme
            ? vegasHunterNextUri
            : vegasHunterCurrentUri.resolveUri(vegasHunterNextUri);
        continue;
      }

      return vegasHunterCurrentUri.toString();
    }

    return vegasHunterCurrentUri.toString();
  } catch (vegasHunterError) {
    debugPrint('wheelFinalUrl error: $vegasHunterError');
    return vegasHunterStartUrl;
  } finally {
    vegasHunterClient.close(force: true);
  }
}

Future<void> vegasHunterPostStat({
  required String vegasHunterEvent,
  required int vegasHunterTimeStart,
  required String vegasHunterUrl,
  required int vegasHunterTimeFinish,
  required String vegasHunterAppSid,
  int? vegasHunterFirstPageTs,
}) async {
  try {
    final String vegasHunterResolvedUrl =
    await vegasHunterFinalUrl(vegasHunterUrl);
    final Map<String, dynamic> vegasHunterPayload = <String, dynamic>{
      'event': vegasHunterEvent,
      'timestart': vegasHunterTimeStart,
      'timefinsh': vegasHunterTimeFinish,
      'url': vegasHunterResolvedUrl,
      'appleID': '6755681349',
      'open_count': '$vegasHunterAppSid/$vegasHunterTimeStart',
    };

    debugPrint('wheelStat $vegasHunterPayload');

    final http.Response vegasHunterResponse = await http.post(
      Uri.parse('$vegasHunterMetrStatEndpoint/$vegasHunterAppSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(vegasHunterPayload),
    );

    debugPrint(
        'wheelStat resp=${vegasHunterResponse.statusCode} body=${vegasHunterResponse.body}');
  } catch (vegasHunterError) {
    debugPrint('wheelPostStat error: $vegasHunterError');
  }
}

// ============================================================================
// WebView-экран: VegasHunterTableView (бывший DressRetroTableView / NcupTableView)
// SafeArea + SafeArea color + localStorage подхватываются из SharedPreferences
// ============================================================================

class VegasHunterTableView extends StatefulWidget
    with WidgetsBindingObserver {
  String vegasHunterStartingUrl;
  VegasHunterTableView(this.vegasHunterStartingUrl, {super.key});

  @override
  State<VegasHunterTableView> createState() =>
      _VegasHunterTableViewState(vegasHunterStartingUrl);
}

class _VegasHunterTableViewState extends State<VegasHunterTableView>
    with WidgetsBindingObserver {
  _VegasHunterTableViewState(this.vegasHunterCurrentUrl);

  final VegasHunterVault vegasHunterVaultInstance = VegasHunterVault();

  late InAppWebViewController vegasHunterWebViewController;
  String? vegasHunterPushToken;
  final VegasHunterDeviceProfile vegasHunterDeviceProfileInstance =
  VegasHunterDeviceProfile();
  final VegasHunterSpy vegasHunterSpyInstance = VegasHunterSpy();

  bool vegasHunterOverlayBusy = false;
  String vegasHunterCurrentUrl;
  DateTime? vegasHunterLastPausedAt;

  bool vegasHunterLoadedOnceSent = false;
  int? vegasHunterFirstPageTimestamp;
  int vegasHunterStartLoadTimestamp = 0;

  // --------- Социальные / внешние хосты / схемы ---------

  final Set<String> vegasHunterExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'bnl.com',
    'www.bnl.com',
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'instagram.com',
    'www.instagram.com',
    'twitter.com',
    'www.twitter.com',
    'x.com',
    'www.x.com',
  };

  final Set<String> vegasHunterExternalSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'bnl',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
  };

  final Set<String> vegasHunterSpecialSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  // --------- UserAgent + SafeArea ---------

  String? _vegasHunterBaseUserAgent;
  String _vegasHunterCurrentUserAgent = '';
  String? _vegasHunterServerUserAgent;
  bool _vegasHunterIsInGoogleAuth = false;

  bool _vegasHunterSafeAreaEnabled = false;
  Color _vegasHunterSafeAreaBackgroundColor = Colors.black;

  // --------- POPUP (window.open) ---------

  InAppWebViewController? _vegasHunterPopupWebViewController;
  bool _vegasHunterIsPopupVisible = false;
  String? _vegasHunterPopupUrl;
  CreateWindowAction? _vegasHunterPopupCreateAction;
  bool _vegasHunterPopupCanGoBack = false;
  String? _vegasHunterPopupCurrentUrl;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    FirebaseMessaging.onBackgroundMessage(vegasHunterFcmBackgroundHandler);

    vegasHunterFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;

    // 1) SafeArea state (enabled + color) подхватываем из SharedPreferences
    _vegasHunterLoadSafeAreaFromPrefs();

    // 2) Push
    vegasHunterInitPushAndGetToken();

    // 3) Профиль устройства -> localStorage + SharedPreferences (app_data)
    vegasHunterDeviceProfileInstance.vegasHunterInitialize().then((_) async {
      if (!mounted) return;
      await _vegasHunterUpdateLocalStorage();
    });

    // 4) FCM + AppsFlyer
    vegasHunterWireForegroundPushHandlers();
    vegasHunterBindPlatformNotificationTap();
    vegasHunterSpyInstance.vegasHunterStart(vegasHunterOnUpdate: () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState vegasHunterState) {
    if (vegasHunterState == AppLifecycleState.paused) {
      vegasHunterLastPausedAt = DateTime.now();
    }
    if (vegasHunterState == AppLifecycleState.resumed) {
      if (Platform.isIOS && vegasHunterLastPausedAt != null) {
        final DateTime vegasHunterNow = DateTime.now();
        final Duration vegasHunterDrift =
        vegasHunterNow.difference(vegasHunterLastPausedAt!);
        if (vegasHunterDrift > const Duration(minutes: 25)) {
          vegasHunterForceReloadToLobby();
        }
      }
      vegasHunterLastPausedAt = null;
    }
  }

  void vegasHunterForceReloadToLobby() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback(
            (Duration vegasHunterDuration) {
          if (!mounted) return;
          // здесь можно вернуть в MafiaHarbor/CaptainHarbor/BillHarbor при необходимости
        });
  }

  // --------------------------------------------------------------------------
  // Push / FCM
  // --------------------------------------------------------------------------

  void vegasHunterWireForegroundPushHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage vegasHunterMsg) {
      if (vegasHunterMsg.data['uri'] != null) {
        vegasHunterNavigateTo(vegasHunterMsg.data['uri'].toString());
      } else {
        vegasHunterReturnToCurrentUrl();
      }
    });

    FirebaseMessaging.onMessageOpenedApp
        .listen((RemoteMessage vegasHunterMsg) {
      if (vegasHunterMsg.data['uri'] != null) {
        vegasHunterNavigateTo(vegasHunterMsg.data['uri'].toString());
      } else {
        vegasHunterReturnToCurrentUrl();
      }
    });
  }

  void vegasHunterNavigateTo(String vegasHunterNewUrl) async {
    await vegasHunterWebViewController.loadUrl(
      urlRequest: URLRequest(url: WebUri(vegasHunterNewUrl)),
    );
  }

  void vegasHunterReturnToCurrentUrl() async {
    Future<void>.delayed(const Duration(seconds: 3), () {
      vegasHunterWebViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(vegasHunterCurrentUrl)),
      );
    });
  }

  Future<void> vegasHunterInitPushAndGetToken() async {
    final FirebaseMessaging vegasHunterFm = FirebaseMessaging.instance;
    await vegasHunterFm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    vegasHunterPushToken = await vegasHunterFm.getToken();
  }

  // --------------------------------------------------------------------------
  // Привязка канала: тап по уведомлению из native
  // --------------------------------------------------------------------------

  void vegasHunterBindPlatformNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall vegasHunterCall) async {
      if (vegasHunterCall.method == "onNotificationTap") {
        final Map<String, dynamic> vegasHunterPayload =
        Map<String, dynamic>.from(vegasHunterCall.arguments);
        debugPrint("URI from platform tap: ${vegasHunterPayload['uri']}");
        final String? vegasHunterUriString =
        vegasHunterPayload["uri"]?.toString();
        if (vegasHunterUriString != null &&
            !vegasHunterUriString.contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext vegasHunterContext) =>
                  VegasHunterTableView(vegasHunterUriString),
            ),
                (Route<dynamic> vegasHunterRoute) => false,
          );
        }
      }
    });
  }

  // --------------------------------------------------------------------------
  // localStorage + SharedPreferences: профиль устройства
  // --------------------------------------------------------------------------

  /// Обновляем app_data в localStorage И синхронно сохраняем JSON в SharedPreferences
  Future<void> _vegasHunterUpdateLocalStorage() async {
    try {
      final Map<String, dynamic> vegasHunterData =
      vegasHunterDeviceProfileInstance.vegasHunterAsMap(
          vegasHunterFcmToken: vegasHunterPushToken);

      final String vegasHunterJson = jsonEncode(vegasHunterData);

      // 1) В localStorage WebView
      await vegasHunterWebViewController.evaluateJavascript(
        source:
        "localStorage.setItem('app_data', JSON.stringify($vegasHunterJson));",
      );

      // 2) В SharedPreferences (чтобы при следующем запуске можно было восстановить)
      final SharedPreferences vegasHunterPrefs =
      await SharedPreferences.getInstance();
      await vegasHunterPrefs.setString('app_data', vegasHunterJson);

      vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogInfo(
          'app_data saved to localStorage & SharedPreferences: $vegasHunterJson');
    } catch (vegasHunterError, vegasHunterStack) {
      vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogError(
          'updateLocalStorage error: $vegasHunterError\n$vegasHunterStack');
    }
  }

  /// Восстанавливаем app_data из SharedPreferences обратно в localStorage
  Future<void> _vegasHunterRestoreAppDataFromPrefsToLocalStorage() async {
    try {
      final SharedPreferences vegasHunterPrefs =
      await SharedPreferences.getInstance();
      final String? vegasHunterSavedJson =
      vegasHunterPrefs.getString('app_data');
      if (vegasHunterSavedJson == null || vegasHunterSavedJson.isEmpty) {
        return;
      }

      final String vegasHunterJs =
          "localStorage.setItem('app_data', JSON.stringify($vegasHunterSavedJson));";

      await vegasHunterWebViewController.evaluateJavascript(
          source: vegasHunterJs);

      vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogInfo(
          'app_data restored from SharedPreferences to localStorage: $vegasHunterSavedJson');
    } catch (vegasHunterError, vegasHunterStack) {
      vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogError(
          '_restoreAppDataFromPrefsToLocalStorage error: $vegasHunterError\n$vegasHunterStack');
    }
  }

  // --------------------------------------------------------------------------
  // UserAgent / SafeArea helpers
  // --------------------------------------------------------------------------

  bool _vegasHunterIsGoogleUrl(Uri vegasHunterUri) {
    final String vegasHunterFull = vegasHunterUri.toString().toLowerCase();
    return vegasHunterFull.contains('google');
  }

  Future<void> _vegasHunterApplyUserAgent(
      {String? vegasHunterFullUa, String? vegasHunterUaTail}) async {
    if (_vegasHunterBaseUserAgent == null ||
        _vegasHunterBaseUserAgent!.trim().isEmpty) {
      try {
        final vegasHunterUa =
        await vegasHunterWebViewController.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (vegasHunterUa is String && vegasHunterUa.trim().isNotEmpty) {
          _vegasHunterBaseUserAgent = vegasHunterUa.trim();
          _vegasHunterCurrentUserAgent = _vegasHunterBaseUserAgent!;
          vegasHunterDeviceProfileInstance.vegasHunterBaseUserAgent =
              _vegasHunterBaseUserAgent;
          vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogInfo(
              'Base User-Agent detected: $_vegasHunterBaseUserAgent');
        }
      } catch (vegasHunterError) {
        vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogWarn(
            'Failed to get base userAgent from JS: $vegasHunterError');
      }
    }

    if (_vegasHunterBaseUserAgent == null ||
        _vegasHunterBaseUserAgent!.trim().isEmpty) {
      vegasHunterVaultInstance.vegasHunterLoggerInstance
          .vegasHunterLogWarn('Base User-Agent is null, skip UA update');
      return;
    }

    String vegasHunterNewUa;
    if (vegasHunterFullUa != null && vegasHunterFullUa.trim().isNotEmpty) {
      vegasHunterNewUa = vegasHunterFullUa.trim();
    } else if (vegasHunterUaTail != null &&
        vegasHunterUaTail.trim().isNotEmpty) {
      vegasHunterNewUa = "${_vegasHunterBaseUserAgent!}/${vegasHunterUaTail.trim()}";
    } else {
      vegasHunterNewUa = _vegasHunterBaseUserAgent!;
    }

    _vegasHunterServerUserAgent = vegasHunterNewUa;
    vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogInfo(
        'Server UA calculated: $_vegasHunterServerUserAgent');
  }

  Future<void> _vegasHunterUpdateUserAgentFromServerPayload(
      Map<dynamic, dynamic> vegasHunterRoot) async {
    String? vegasHunterFullUa;
    String? vegasHunterUaTail;

    final dynamic vegasHunterContent = vegasHunterRoot['content'];
    if (vegasHunterContent is Map) {
      if (vegasHunterContent['fullua'] != null &&
          vegasHunterContent['fullua'].toString().trim().isNotEmpty) {
        vegasHunterFullUa =
            vegasHunterContent['fullua'].toString().trim();
      }
      if (vegasHunterContent['uatail'] != null &&
          vegasHunterContent['uatail'].toString().trim().isNotEmpty) {
        vegasHunterUaTail =
            vegasHunterContent['uatail'].toString().trim();
      }
    }

    if (vegasHunterFullUa == null &&
        vegasHunterRoot['fullua'] != null &&
        vegasHunterRoot['fullua'].toString().trim().isNotEmpty) {
      vegasHunterFullUa =
          vegasHunterRoot['fullua'].toString().trim();
    }
    if (vegasHunterUaTail == null &&
        vegasHunterRoot['uatail'] != null &&
        vegasHunterRoot['uatail'].toString().trim().isNotEmpty) {
      vegasHunterUaTail =
          vegasHunterRoot['uatail'].toString().trim();
    }

    if (vegasHunterUaTail == null) {
      final dynamic vegasHunterAdata = vegasHunterRoot['adata'];
      if (vegasHunterAdata is Map &&
          vegasHunterAdata['uatail'] != null &&
          vegasHunterAdata['uatail'].toString().trim().isNotEmpty) {
        vegasHunterUaTail =
            vegasHunterAdata['uatail'].toString().trim();
      }
    }

    await _vegasHunterApplyUserAgent(
        vegasHunterFullUa: vegasHunterFullUa,
        vegasHunterUaTail: vegasHunterUaTail);
  }

  Future<void> _vegasHunterApplyNormalUserAgentIfNeeded() async {
    if (_vegasHunterIsInGoogleAuth) {
      vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogInfo(
          'Skip normal UA apply because we are in Google auth');
      return;
    }

    final String vegasHunterTargetUa =
        _vegasHunterServerUserAgent ?? _vegasHunterBaseUserAgent ?? 'random';

    if (vegasHunterTargetUa == _vegasHunterCurrentUserAgent) return;

    try {
      await vegasHunterWebViewController.setSettings(
        settings: InAppWebViewSettings(userAgent: vegasHunterTargetUa),
      );
      _vegasHunterCurrentUserAgent = vegasHunterTargetUa;
      debugPrint(
          '[UA] NORMAL WEBVIEW USER AGENT: $_vegasHunterCurrentUserAgent');
    } catch (vegasHunterError) {
      vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogError(
          'Error while setting UA "$vegasHunterTargetUa": $vegasHunterError');
    }
  }

  Future<void> _vegasHunterAddRandomToUserAgentForGoogle() async {
    const String vegasHunterTargetUa = 'random';
    if (_vegasHunterCurrentUserAgent == vegasHunterTargetUa &&
        _vegasHunterIsInGoogleAuth) return;

    try {
      await vegasHunterWebViewController.setSettings(
        settings: InAppWebViewSettings(userAgent: vegasHunterTargetUa),
      );
      _vegasHunterCurrentUserAgent = vegasHunterTargetUa;
      _vegasHunterIsInGoogleAuth = true;
      debugPrint(
          '[UA] GOOGLE RANDOM USER AGENT: $_vegasHunterCurrentUserAgent');
    } catch (vegasHunterError) {
      vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogError(
          'Error setting RANDOM UA for Google: $vegasHunterError');
    }
  }

  Future<void> _vegasHunterRestoreUserAgentAfterGoogleIfNeeded() async {
    if (!_vegasHunterIsInGoogleAuth) return;
    _vegasHunterIsInGoogleAuth = false;
    await _vegasHunterApplyNormalUserAgentIfNeeded();
  }

  // Хелпер для парсинга HEX‑цвета (общий для SafeArea и prefs)
  Color _vegasHunterParseHexColor(
      String vegasHunterHex, {
        Color vegasHunterFallback = const Color(0xFF1A1A22),
      }) {
    String vegasHunterValue = vegasHunterHex.trim();
    if (vegasHunterValue.startsWith('#')) {
      vegasHunterValue = vegasHunterValue.substring(1);
    }
    if (vegasHunterValue.length == 6) {
      vegasHunterValue = 'FF$vegasHunterValue';
    }
    final int? vegasHunterIntColor =
    int.tryParse(vegasHunterValue, radix: 16);
    if (vegasHunterIntColor == null) return vegasHunterFallback;
    return Color(vegasHunterIntColor);
  }

  // НОВОЕ: загрузка SafeArea из SharedPreferences при старте
  Future<void> _vegasHunterLoadSafeAreaFromPrefs() async {
    try {
      final SharedPreferences vegasHunterPrefs =
      await SharedPreferences.getInstance();
      final bool vegasHunterEnabled =
          vegasHunterPrefs.getBool(vegasHunterSafeAreaEnabledKey) ?? false;
      final String vegasHunterColorHex =
          vegasHunterPrefs.getString(vegasHunterSafeAreaColorKey) ?? '';

      Color vegasHunterBg = Colors.black;
      if (vegasHunterEnabled) {
        if (vegasHunterColorHex.isNotEmpty) {
          vegasHunterBg = _vegasHunterParseHexColor(vegasHunterColorHex,
              vegasHunterFallback: const Color(0xFF1A1A22));
        } else {
          vegasHunterBg = const Color(0xFF1A1A22);
        }
      }

      if (!mounted) return;

      setState(() {
        _vegasHunterSafeAreaEnabled = vegasHunterEnabled;
        _vegasHunterSafeAreaBackgroundColor = vegasHunterBg;
        vegasHunterDeviceProfileInstance.vegasHunterSafeAreaEnabled =
            vegasHunterEnabled;
        vegasHunterDeviceProfileInstance.vegasHunterSafeAreaColor =
        vegasHunterEnabled
            ? (vegasHunterColorHex.isNotEmpty
            ? vegasHunterColorHex
            : '#1A1A22')
            : '';
      });

      vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogInfo(
          'SafeArea loaded from prefs: enabled=$vegasHunterEnabled, color="$vegasHunterColorHex"');
    } catch (vegasHunterError, vegasHunterStack) {
      vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogError(
          '_loadSafeAreaFromPrefs error: $vegasHunterError\n$vegasHunterStack');
    }
  }

  void _vegasHunterUpdateSafeAreaFromServerPayload(
      Map<dynamic, dynamic> vegasHunterRoot) {
    bool? vegasHunterSafeAreaFlag;
    String? vegasHunterBgLightHex;
    String? vegasHunterBgDarkHex;

    final dynamic vegasHunterContent = vegasHunterRoot['content'];
    if (vegasHunterContent is Map) {
      if (vegasHunterContent['safearea'] != null) {
        final dynamic vegasHunterRaw = vegasHunterContent['safearea'];
        if (vegasHunterRaw is bool) {
          vegasHunterSafeAreaFlag = vegasHunterRaw;
        } else if (vegasHunterRaw is String) {
          final String vegasHunterValue =
          vegasHunterRaw.toLowerCase().trim();
          if (vegasHunterValue == 'true' ||
              vegasHunterValue == '1' ||
              vegasHunterValue == 'yes') {
            vegasHunterSafeAreaFlag = true;
          }
          if (vegasHunterValue == 'false' ||
              vegasHunterValue == '0' ||
              vegasHunterValue == 'no') {
            vegasHunterSafeAreaFlag = false;
          }
        } else if (vegasHunterRaw is num) {
          vegasHunterSafeAreaFlag = vegasHunterRaw != 0;
        }
      }

      if (vegasHunterContent['safearea_color'] != null &&
          vegasHunterContent['safearea_color']
              .toString()
              .trim()
              .isNotEmpty) {
        vegasHunterBgLightHex =
            vegasHunterContent['safearea_color'].toString().trim();
        vegasHunterBgDarkHex = vegasHunterBgLightHex;
      }
    }

    final dynamic vegasHunterAdata = vegasHunterRoot['adata'];
    if (vegasHunterAdata is Map) {
      if (vegasHunterSafeAreaFlag == null &&
          vegasHunterAdata['safearea'] != null) {
        final dynamic vegasHunterRaw = vegasHunterAdata['safearea'];
        if (vegasHunterRaw is bool) {
          vegasHunterSafeAreaFlag = vegasHunterRaw;
        } else if (vegasHunterRaw is String) {
          final String vegasHunterValue =
          vegasHunterRaw.toLowerCase().trim();
          if (vegasHunterValue == 'true' ||
              vegasHunterValue == '1' ||
              vegasHunterValue == 'yes') {
            vegasHunterSafeAreaFlag = true;
          }
          if (vegasHunterValue == 'false' ||
              vegasHunterValue == '0' ||
              vegasHunterValue == 'no') {
            vegasHunterSafeAreaFlag = false;
          }
        } else if (vegasHunterRaw is num) {
          vegasHunterSafeAreaFlag = vegasHunterRaw != 0;
        }
      }

      if (vegasHunterAdata['bgsareaw'] != null &&
          vegasHunterAdata['bgsareaw'].toString().trim().isNotEmpty) {
        vegasHunterBgLightHex =
            vegasHunterAdata['bgsareaw'].toString().trim();
      }
      if (vegasHunterAdata['bgsareab'] != null &&
          vegasHunterAdata['bgsareab'].toString().trim().isNotEmpty) {
        vegasHunterBgDarkHex =
            vegasHunterAdata['bgsareab'].toString().trim();
      }
    }

    if (vegasHunterSafeAreaFlag == null &&
        vegasHunterRoot['safearea'] != null) {
      final dynamic vegasHunterRaw = vegasHunterRoot['safearea'];
      if (vegasHunterRaw is bool) {
        vegasHunterSafeAreaFlag = vegasHunterRaw;
      } else if (vegasHunterRaw is String) {
        final String vegasHunterValue =
        vegasHunterRaw.toLowerCase().trim();
        if (vegasHunterValue == 'true' ||
            vegasHunterValue == '1' ||
            vegasHunterValue == 'yes') {
          vegasHunterSafeAreaFlag = true;
        }
        if (vegasHunterValue == 'false' ||
            vegasHunterValue == '0' ||
            vegasHunterValue == 'no') {
          vegasHunterSafeAreaFlag = false;
        }
      } else if (vegasHunterRaw is num) {
        vegasHunterSafeAreaFlag = vegasHunterRaw != 0;
      }
    }

    if (vegasHunterSafeAreaFlag == null) return;

    final Brightness vegasHunterPlatformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? vegasHunterChosenHex;
    if (vegasHunterPlatformBrightness == Brightness.light) {
      vegasHunterChosenHex = vegasHunterBgLightHex ?? vegasHunterBgDarkHex;
    } else {
      vegasHunterChosenHex = vegasHunterBgDarkHex ?? vegasHunterBgLightHex;
    }

    Color vegasHunterBackgroundColor =
    vegasHunterSafeAreaFlag ? const Color(0xFF1A1A22) : Colors.black;

    if (vegasHunterSafeAreaFlag &&
        vegasHunterChosenHex != null &&
        vegasHunterChosenHex.isNotEmpty) {
      vegasHunterBackgroundColor = _vegasHunterParseHexColor(
          vegasHunterChosenHex,
          vegasHunterFallback: const Color(0xFF1A1A22));
    }

    setState(() {
      _vegasHunterSafeAreaEnabled = vegasHunterSafeAreaFlag!;
      _vegasHunterSafeAreaBackgroundColor = vegasHunterBackgroundColor;
      vegasHunterDeviceProfileInstance.vegasHunterSafeAreaEnabled =
          vegasHunterSafeAreaFlag;
      vegasHunterDeviceProfileInstance.vegasHunterSafeAreaColor =
      vegasHunterSafeAreaFlag
          ? (vegasHunterChosenHex ?? '#1A1A22')
          : '';
    });

    // НОВОЕ: сохраняем SafeArea в SharedPreferences при каждом обновлении
    () async {
      try {
        final SharedPreferences vegasHunterPrefs =
            await SharedPreferences.getInstance();
        await vegasHunterPrefs.setBool(
            vegasHunterSafeAreaEnabledKey, vegasHunterSafeAreaFlag!);
        await vegasHunterPrefs.setString(
          vegasHunterSafeAreaColorKey,
          vegasHunterDeviceProfileInstance.vegasHunterSafeAreaColor ?? '',
        );
        vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogInfo(
          'SafeArea saved to prefs: enabled=$vegasHunterSafeAreaFlag, color="${vegasHunterDeviceProfileInstance.vegasHunterSafeAreaColor}"',
        );
      } catch (vegasHunterError, vegasHunterStack) {
        vegasHunterVaultInstance.vegasHunterLoggerInstance.vegasHunterLogError(
            'Error saving SafeArea to prefs: $vegasHunterError\n$vegasHunterStack');
      }
    }();
  }

  // --------------------------------------------------------------------------
  // POPUP helpers
  // --------------------------------------------------------------------------

  InAppWebViewSettings _vegasHunterPopupSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: false,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  void _vegasHunterOpenPopup(
      CreateWindowAction vegasHunterRequest, {
        String? vegasHunterUrlString,
      }) {
    setState(() {
      _vegasHunterPopupCreateAction = vegasHunterRequest;
      _vegasHunterPopupUrl =
      (vegasHunterUrlString != null && vegasHunterUrlString.isNotEmpty)
          ? vegasHunterUrlString
          : vegasHunterRequest.request.url?.toString();
      _vegasHunterPopupCurrentUrl = _vegasHunterPopupUrl;
      _vegasHunterIsPopupVisible = true;
      _vegasHunterPopupCanGoBack = false;
    });
  }

  void _vegasHunterClosePopup() {
    setState(() {
      _vegasHunterIsPopupVisible = false;
      _vegasHunterPopupUrl = null;
      _vegasHunterPopupCurrentUrl = null;
      _vegasHunterPopupCreateAction = null;
      _vegasHunterPopupCanGoBack = false;
      _vegasHunterPopupWebViewController = null;
    });
  }

  Future<void> _vegasHunterRefreshPopupCanGoBack() async {
    final InAppWebViewController? vegasHunterController =
        _vegasHunterPopupWebViewController;
    if (vegasHunterController == null) {
      if (_vegasHunterPopupCanGoBack && mounted) {
        setState(() {
          _vegasHunterPopupCanGoBack = false;
        });
      }
      return;
    }
    try {
      final bool vegasHunterCanGoBack =
      await vegasHunterController.canGoBack();
      if (!mounted) return;
      if (vegasHunterCanGoBack != _vegasHunterPopupCanGoBack) {
        setState(() {
          _vegasHunterPopupCanGoBack = vegasHunterCanGoBack;
        });
      }
    } catch (_) {}
  }

  Future<void> _vegasHunterHandlePopupBackPressed() async {
    final InAppWebViewController? vegasHunterController =
        _vegasHunterPopupWebViewController;
    if (vegasHunterController == null) {
      _vegasHunterClosePopup();
      return;
    }
    try {
      if (await vegasHunterController.canGoBack()) {
        await vegasHunterController.goBack();
        Future<void>.delayed(const Duration(milliseconds: 200), () {
          _vegasHunterRefreshPopupCanGoBack();
        });
      } else {
        _vegasHunterClosePopup();
      }
    } catch (_) {
      _vegasHunterClosePopup();
    }
  }

  Widget _vegasHunterBuildPopupOverlay() {
    if (!_vegasHunterIsPopupVisible ||
        (_vegasHunterPopupUrl == null &&
            _vegasHunterPopupCreateAction == null)) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Container(
                color: Colors.black,
                height: 48,
                child: Row(
                  children: [
                    if (_vegasHunterPopupCanGoBack)
                      IconButton(
                        icon:
                        const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: _vegasHunterHandlePopupBackPressed,
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: _vegasHunterClosePopup,
                      ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Expanded(
              child: InAppWebView(
                windowId: _vegasHunterPopupCreateAction?.windowId,
                initialUrlRequest: (_vegasHunterPopupCreateAction?.windowId ==
                    null &&
                    _vegasHunterPopupUrl != null)
                    ? URLRequest(url: WebUri(_vegasHunterPopupUrl!))
                    : null,
                initialSettings: _vegasHunterPopupSettings(),
                onWebViewCreated:
                    (InAppWebViewController vegasHunterController) async {
                  _vegasHunterPopupWebViewController = vegasHunterController;
                },
                onLoadStart: (vegasHunterController, vegasHunterUri) async {
                  if (vegasHunterUri != null) {
                    setState(() {
                      _vegasHunterPopupCurrentUrl =
                          vegasHunterUri.toString();
                    });
                  }
                  await _vegasHunterRefreshPopupCanGoBack();
                },
                onPermissionRequest:
                    (vegasHunterController, vegasHunterRequest) async {
                  return PermissionResponse(
                    resources: vegasHunterRequest.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStop: (vegasHunterController, vegasHunterUri) async {
                  if (vegasHunterUri != null) {
                    setState(() {
                      _vegasHunterPopupCurrentUrl =
                          vegasHunterUri.toString();
                    });
                  }
                  await _vegasHunterRefreshPopupCanGoBack();
                },
                onUpdateVisitedHistory:
                    (vegasHunterController, vegasHunterUrl, vegasHunterReload) async {
                  if (vegasHunterUrl != null) {
                    setState(() {
                      _vegasHunterPopupCurrentUrl =
                          vegasHunterUrl.toString();
                    });
                  }
                  await _vegasHunterRefreshPopupCanGoBack();
                },
                shouldOverrideUrlLoading: (
                    InAppWebViewController vegasHunterController,
                    NavigationAction vegasHunterNav,
                    ) async {
                  final Uri? vegasHunterUri =
                      vegasHunterNav.request.url;
                  if (vegasHunterUri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  final String vegasHunterScheme =
                  vegasHunterUri.scheme.toLowerCase();

                  if (VegasHunterKit.vegasHunterLooksLikeBareMail(
                      vegasHunterUri)) {
                    final Uri vegasHunterMailto =
                    VegasHunterKit.vegasHunterToMailto(
                        vegasHunterUri);
                    await VegasHunterLinker.vegasHunterOpen(
                        VegasHunterKit.vegasHunterGmailize(
                            vegasHunterMailto));
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (vegasHunterScheme == 'mailto') {
                    await VegasHunterLinker.vegasHunterOpen(
                        VegasHunterKit.vegasHunterGmailize(
                            vegasHunterUri));
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (vegasHunterScheme == 'tel') {
                    await launchUrl(
                      vegasHunterUri,
                      mode: LaunchMode.externalApplication,
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (vegasHunterIsBankScheme(vegasHunterUri) ||
                      ((vegasHunterScheme == 'http' ||
                          vegasHunterScheme == 'https') &&
                          vegasHunterIsBankDomain(vegasHunterUri))) {
                    await vegasHunterOpenBank(vegasHunterUri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (vegasHunterScheme != 'http' &&
                      vegasHunterScheme != 'https') {
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (vegasHunterController) {
                  _vegasHunterClosePopup();
                },
                onDownloadStartRequest:
                    (vegasHunterController, vegasHunterRequest) async {
                  await VegasHunterLinker.vegasHunterOpen(
                      vegasHunterRequest.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    vegasHunterBindPlatformNotificationTap();

    final bool vegasHunterIsDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;

    final Color vegasHunterBgColor = _vegasHunterSafeAreaEnabled
        ? _vegasHunterSafeAreaBackgroundColor
        : (vegasHunterIsDark ? Colors.black : Colors.white);

    final Widget vegasHunterWebView = InAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        disableDefaultErrorPage: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        allowsPictureInPictureMediaPlayback: true,
        useOnDownloadStart: true,
        javaScriptCanOpenWindowsAutomatically: true,
        useShouldOverrideUrlLoading: true,
        supportMultipleWindows: true,
      ),
      initialUrlRequest: URLRequest(
        url: WebUri(vegasHunterCurrentUrl),
      ),
      onWebViewCreated:
          (InAppWebViewController vegasHunterController) async {
        vegasHunterWebViewController = vegasHunterController;

        // Инициализация UA
        try {
          final vegasHunterUa =
          await vegasHunterController.evaluateJavascript(
            source: "navigator.userAgent",
          );
          if (vegasHunterUa is String &&
              vegasHunterUa.trim().isNotEmpty) {
            _vegasHunterBaseUserAgent = vegasHunterUa.trim();
            _vegasHunterCurrentUserAgent = _vegasHunterBaseUserAgent!;
            vegasHunterDeviceProfileInstance.vegasHunterBaseUserAgent =
                _vegasHunterBaseUserAgent;
            debugPrint('[UA] INITIAL: $_vegasHunterBaseUserAgent');
          }
        } catch (vegasHunterError) {
          vegasHunterVaultInstance.vegasHunterLoggerInstance
              .vegasHunterLogWarn(
              'Failed to read navigator.userAgent: $vegasHunterError');
        }

        await _vegasHunterApplyNormalUserAgentIfNeeded();

        // После создания WebView — актуализируем localStorage
        await _vegasHunterUpdateLocalStorage();

        // Через 6 секунд после открытия экрана — восстановление app_data из SharedPreferences
        Future<void>.delayed(const Duration(seconds: 6), () async {
          if (!mounted) return;
          await _vegasHunterRestoreAppDataFromPrefsToLocalStorage();
        });

        vegasHunterWebViewController.addJavaScriptHandler(
          handlerName: 'onServerResponse',
          callback: (List<dynamic> vegasHunterArgs) {
            vegasHunterVaultInstance.vegasHunterLoggerInstance
                .vegasHunterLogInfo("JS Args: $vegasHunterArgs");

            try {
              dynamic vegasHunterFirst =
              vegasHunterArgs.isNotEmpty ? vegasHunterArgs[0] : null;

              if (vegasHunterFirst is List &&
                  vegasHunterFirst.isNotEmpty) {
                vegasHunterFirst = vegasHunterFirst.first;
              }

              if (vegasHunterFirst is Map) {
                final Map<dynamic, dynamic> vegasHunterRoot =
                    vegasHunterFirst;

                // safearea + userAgent из сервера
                _vegasHunterUpdateSafeAreaFromServerPayload(
                    vegasHunterRoot);
                _vegasHunterUpdateUserAgentFromServerPayload(
                    vegasHunterRoot);
                _vegasHunterApplyNormalUserAgentIfNeeded();

                // При каждом ответе сервера можно обновлять localStorage
                _vegasHunterUpdateLocalStorage();
              }

              try {
                return vegasHunterArgs.reduce(
                        (dynamic vegasHunterValue, dynamic vegasHunterElement) =>
                    vegasHunterValue + vegasHunterElement);
              } catch (_) {
                return vegasHunterArgs.toString();
              }
            } catch (vegasHunterError) {
              return vegasHunterArgs.toString();
            }
          },
        );
      },
      onLoadStart: (
          InAppWebViewController vegasHunterController,
          Uri? vegasHunterUri,
          ) async {
        vegasHunterStartLoadTimestamp =
            DateTime.now().millisecondsSinceEpoch;

        if (vegasHunterUri != null) {
          if (_vegasHunterIsGoogleUrl(vegasHunterUri)) {
            await _vegasHunterAddRandomToUserAgentForGoogle();
          } else {
            await _vegasHunterRestoreUserAgentAfterGoogleIfNeeded();
            await _vegasHunterApplyNormalUserAgentIfNeeded();
          }

          if (VegasHunterKit.vegasHunterLooksLikeBareMail(
              vegasHunterUri)) {
            try {
              await vegasHunterController.stopLoading();
            } catch (_) {}
            final Uri vegasHunterMailto =
            VegasHunterKit.vegasHunterToMailto(
                vegasHunterUri);
            await VegasHunterLinker.vegasHunterOpen(
              VegasHunterKit.vegasHunterGmailize(
                  vegasHunterMailto),
            );
            return;
          }

          // банки
          if (vegasHunterIsBankScheme(vegasHunterUri) ||
              ((vegasHunterUri.scheme == 'http' ||
                  vegasHunterUri.scheme == 'https') &&
                  vegasHunterIsBankDomain(vegasHunterUri))) {
            try {
              await vegasHunterController.stopLoading();
            } catch (_) {}
            await vegasHunterOpenBank(vegasHunterUri);
            return;
          }

          final String vegasHunterScheme =
          vegasHunterUri.scheme.toLowerCase();
          if (vegasHunterScheme != 'http' &&
              vegasHunterScheme != 'https') {
            try {
              await vegasHunterController.stopLoading();
            } catch (_) {}
          }
        }
      },
      onLoadStop: (
          InAppWebViewController vegasHunterController,
          Uri? vegasHunterUri,
          ) async {
        await vegasHunterController.evaluateJavascript(
          source: "console.log('Hello from Roulette JS!');",
        );

        setState(() {
          vegasHunterCurrentUrl =
              vegasHunterUri?.toString() ?? vegasHunterCurrentUrl;
        });

        await _vegasHunterRestoreUserAgentAfterGoogleIfNeeded();
        await _vegasHunterApplyNormalUserAgentIfNeeded();

        // После полной загрузки страницы обновляем localStorage
        await _vegasHunterUpdateLocalStorage();

        // И сразу тянем app_data из SharedPreferences в localStorage
        await _vegasHunterRestoreAppDataFromPrefsToLocalStorage();

        Future<void>.delayed(const Duration(seconds: 20), () {
          vegasHunterSendLoadedOnce();
        });
      },
      shouldOverrideUrlLoading: (
          InAppWebViewController vegasHunterController,
          NavigationAction vegasHunterNav,
          ) async {
        final Uri? vegasHunterUri = vegasHunterNav.request.url;
        if (vegasHunterUri == null) {
          return NavigationActionPolicy.ALLOW;
        }

        if (_vegasHunterIsGoogleUrl(vegasHunterUri)) {
          await _vegasHunterAddRandomToUserAgentForGoogle();
        } else {
          await _vegasHunterRestoreUserAgentAfterGoogleIfNeeded();
          await _vegasHunterApplyNormalUserAgentIfNeeded();
        }

        if (VegasHunterKit.vegasHunterLooksLikeBareMail(
            vegasHunterUri)) {
          final Uri vegasHunterMailto =
          VegasHunterKit.vegasHunterToMailto(
              vegasHunterUri);
          await VegasHunterLinker.vegasHunterOpen(
            VegasHunterKit.vegasHunterGmailize(
                vegasHunterMailto),
          );
          return NavigationActionPolicy.CANCEL;
        }

        final String vegasHunterScheme =
        vegasHunterUri.scheme.toLowerCase();

        if (vegasHunterScheme == 'mailto') {
          await VegasHunterLinker.vegasHunterOpen(
            VegasHunterKit.vegasHunterGmailize(
                vegasHunterUri),
          );
          return NavigationActionPolicy.CANCEL;
        }

        if (vegasHunterIsBankScheme(vegasHunterUri) ||
            ((vegasHunterScheme == 'http' ||
                vegasHunterScheme == 'https') &&
                vegasHunterIsBankDomain(vegasHunterUri))) {
          await vegasHunterOpenBank(vegasHunterUri);
          return NavigationActionPolicy.CANCEL;
        }

        if (vegasHunterScheme == 'tel') {
          await launchUrl(
            vegasHunterUri,
            mode: LaunchMode.externalApplication,
          );
          return NavigationActionPolicy.CANCEL;
        }

        final String vegasHunterHost =
        vegasHunterUri.host.toLowerCase();
        final bool vegasHunterIsSocial =
            vegasHunterHost.endsWith('facebook.com') ||
                vegasHunterHost.endsWith('instagram.com') ||
                vegasHunterHost.endsWith('twitter.com') ||
                vegasHunterHost.endsWith('x.com');

        if (vegasHunterIsSocial) {
          await VegasHunterLinker.vegasHunterOpen(
              vegasHunterUri);
          return NavigationActionPolicy.CANCEL;
        }

        if (vegasHunterIsExternalDestination(vegasHunterUri)) {
          final Uri vegasHunterMapped =
          vegasHunterMapExternalToHttp(vegasHunterUri);
          await VegasHunterLinker.vegasHunterOpen(vegasHunterMapped);
          return NavigationActionPolicy.CANCEL;
        }

        if (vegasHunterScheme != 'http' &&
            vegasHunterScheme != 'https') {
          return NavigationActionPolicy.CANCEL;
        }

        return NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (
          InAppWebViewController vegasHunterController,
          CreateWindowAction vegasHunterReq,
          ) async {
        final Uri? vegasHunterUrl = vegasHunterReq.request.url;
        if (vegasHunterUrl == null) return false;

        if (_vegasHunterIsGoogleUrl(vegasHunterUrl)) {
          await _vegasHunterAddRandomToUserAgentForGoogle();
        } else {
          await _vegasHunterRestoreUserAgentAfterGoogleIfNeeded();
          await _vegasHunterApplyNormalUserAgentIfNeeded();
        }

        if (VegasHunterKit.vegasHunterLooksLikeBareMail(
            vegasHunterUrl)) {
          final Uri vegasHunterMail =
          VegasHunterKit.vegasHunterToMailto(
              vegasHunterUrl);
          await VegasHunterLinker.vegasHunterOpen(
            VegasHunterKit.vegasHunterGmailize(
                vegasHunterMail),
          );
          return false;
        }

        final String vegasHunterScheme =
        vegasHunterUrl.scheme.toLowerCase();

        if (vegasHunterScheme == 'mailto') {
          await VegasHunterLinker.vegasHunterOpen(
            VegasHunterKit.vegasHunterGmailize(
                vegasHunterUrl),
          );
          return false;
        }

        if (vegasHunterIsBankScheme(vegasHunterUrl) ||
            ((vegasHunterScheme == 'http' ||
                vegasHunterScheme == 'https') &&
                vegasHunterIsBankDomain(vegasHunterUrl))) {
          await vegasHunterOpenBank(vegasHunterUrl);
          return false;
        }

        if (vegasHunterScheme == 'tel') {
          await launchUrl(
            vegasHunterUrl,
            mode: LaunchMode.externalApplication,
          );
          return false;
        }

        final String vegasHunterHost =
        vegasHunterUrl.host.toLowerCase();
        final bool vegasHunterIsSocial =
            vegasHunterHost.endsWith('facebook.com') ||
                vegasHunterHost.endsWith('instagram.com') ||
                vegasHunterHost.endsWith('twitter.com') ||
                vegasHunterHost.endsWith('x.com');

        if (vegasHunterIsSocial) {
          await VegasHunterLinker.vegasHunterOpen(
              vegasHunterUrl);
          return false;
        }

        if (vegasHunterIsExternalDestination(vegasHunterUrl)) {
          final Uri vegasHunterMapped =
          vegasHunterMapExternalToHttp(vegasHunterUrl);
          await VegasHunterLinker.vegasHunterOpen(vegasHunterMapped);
          return false;
        }

        // popup-логика: всё, что осталось http/https — открываем во всплывающем WebView
        if (vegasHunterScheme == 'http' ||
            vegasHunterScheme == 'https') {
          _vegasHunterOpenPopup(vegasHunterReq,
              vegasHunterUrlString: vegasHunterUrl.toString());
          return true; // говорим WebView, что создаём окно сами
        }

        return false;
      },
    );

    final Widget vegasHunterBody = Stack(
      children: <Widget>[
        vegasHunterWebView,
        if (vegasHunterOverlayBusy)
          const Positioned.fill(
            child: ColoredBox(
              color: Colors.black87,
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ),
        _vegasHunterBuildPopupOverlay(),
      ],
    );

    final Widget vegasHunterWrapped = _vegasHunterSafeAreaEnabled
        ? SafeArea(child: vegasHunterBody)
        : vegasHunterBody;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: vegasHunterBgColor,
        body: vegasHunterWrapped,
      ),
    );
  }

  // ========================================================================
  // Внешние “столы” (протоколы/мессенджеры/соцсети)
  // ========================================================================

  bool vegasHunterIsExternalDestination(Uri vegasHunterUri) {
    final String vegasHunterScheme =
    vegasHunterUri.scheme.toLowerCase();
    if (vegasHunterExternalSchemes.contains(vegasHunterScheme)) {
      return true;
    }

    if (vegasHunterScheme == 'http' ||
        vegasHunterScheme == 'https') {
      final String vegasHunterHost =
      vegasHunterUri.host.toLowerCase();
      if (vegasHunterExternalHosts.contains(vegasHunterHost)) {
        return true;
      }
      if (vegasHunterHost.endsWith('t.me')) return true;
      if (vegasHunterHost.endsWith('wa.me')) return true;
      if (vegasHunterHost.endsWith('m.me')) return true;
      if (vegasHunterHost.endsWith('signal.me')) return true;
      if (vegasHunterHost.endsWith('facebook.com')) return true;
      if (vegasHunterHost.endsWith('instagram.com')) return true;
      if (vegasHunterHost.endsWith('twitter.com')) return true;
      if (vegasHunterHost.endsWith('x.com')) return true;
    }

    return false;
  }

  Uri vegasHunterMapExternalToHttp(Uri vegasHunterUri) {
    final String vegasHunterScheme =
    vegasHunterUri.scheme.toLowerCase();

    if (vegasHunterScheme == 'tg' || vegasHunterScheme == 'telegram') {
      final Map<String, String> vegasHunterQp =
          vegasHunterUri.queryParameters;
      final String? vegasHunterDomain = vegasHunterQp['domain'];
      if (vegasHunterDomain != null && vegasHunterDomain.isNotEmpty) {
        return Uri.https('t.me', '/$vegasHunterDomain', <String, String>{
          if (vegasHunterQp['start'] != null)
            'start': vegasHunterQp['start']!,
        });
      }
      final String vegasHunterPath =
      vegasHunterUri.path.isNotEmpty ? vegasHunterUri.path : '';
      return Uri.https(
        't.me',
        '/$vegasHunterPath',
        vegasHunterUri.queryParameters.isEmpty
            ? null
            : vegasHunterUri.queryParameters,
      );
    }

    if (vegasHunterScheme == 'whatsapp') {
      final Map<String, String> vegasHunterQp =
          vegasHunterUri.queryParameters;
      final String? vegasHunterPhone = vegasHunterQp['phone'];
      final String? vegasHunterText = vegasHunterQp['text'];
      if (vegasHunterPhone != null && vegasHunterPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${VegasHunterKit.vegasHunterDigitsOnly(vegasHunterPhone)}',
          <String, String>{
            if (vegasHunterText != null && vegasHunterText.isNotEmpty)
              'text': vegasHunterText,
          },
        );
      }
      return Uri.https(
        'wa.me',
        '/',
        <String, String>{
          if (vegasHunterText != null && vegasHunterText.isNotEmpty)
            'text': vegasHunterText,
        },
      );
    }

    if (vegasHunterScheme == 'bnl') {
      final String vegasHunterNewPath =
      vegasHunterUri.path.isNotEmpty ? vegasHunterUri.path : '';
      return Uri.https(
        'bnl.com',
        '/$vegasHunterNewPath',
        vegasHunterUri.queryParameters.isEmpty
            ? null
            : vegasHunterUri.queryParameters,
      );
    }

    return vegasHunterUri;
  }

  Future<void> vegasHunterSendLoadedOnce() async {
    if (vegasHunterLoadedOnceSent) {
      debugPrint('Wheel Loaded already sent, skip');
      return;
    }

    final int vegasHunterNow =
        DateTime.now().millisecondsSinceEpoch;

    await vegasHunterPostStat(
      vegasHunterEvent: 'Loaded',
      vegasHunterTimeStart: vegasHunterStartLoadTimestamp,
      vegasHunterTimeFinish: vegasHunterNow,
      vegasHunterUrl: vegasHunterCurrentUrl,
      vegasHunterAppSid: vegasHunterSpyInstance.vegasHunterAppsFlyerUid,
      vegasHunterFirstPageTs: vegasHunterFirstPageTimestamp,
    );

    vegasHunterLoadedOnceSent = true;
  }
}