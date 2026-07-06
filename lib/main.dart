import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Platform, HttpHeaders, HttpClient, HttpClientRequest, HttpClientResponse;

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as appsflyer_core;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
    MethodChannel,
    SystemChrome,
    SystemUiOverlayStyle,
    MethodCall,
    VoidCallback;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;
import 'package:vegasday/pugh.dart';
import 'package:vegasday/vegasApp.dart';

import 'loading.dart';

// ============================================================================
// Константы
// ============================================================================

const String vegasHunterLoadedOnceKey = 'loaded_once';
const String vegasHunterStatEndpoint = 'https://servlog.vegasday.blog/stat';
const String vegasHunterCachedFcmKey = 'cached_fcm';
const String vegasHunterCachedDeepKey = 'cached_deep_push_uri';

const Set<String> kJackpotSchemes = {
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

const Set<String> kJackpotDomains = {
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
// OneLink / AppsFlyer домены — НЕ открывать во внешнем браузере
// ============================================================================

const Set<String> kRouletteLinkDomains = {
  'onelink.me',
  'app.appsflyer.com',
  'appsflyer.com',
  'af-link.com',
};

/// Проверяет, является ли URL ссылкой OneLink / AppsFlyer
bool VegasHunterIsRouletteUrl(Uri uri) {
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;

  for (final String domain in kRouletteLinkDomains) {
    final String d = domain.toLowerCase();
    if (host == d || host.endsWith('.$d')) {
      return true;
    }
  }
  return false;
}

// ============================================================================
// Лёгкие сервисы
// ============================================================================

class VegasHunterLoggerService {
  static final VegasHunterLoggerService VegasSharedInstance =
  VegasHunterLoggerService._VegasInternalConstructor();

  VegasHunterLoggerService._VegasInternalConstructor();

  factory VegasHunterLoggerService() => VegasSharedInstance;

  final Connectivity VegasConnectivity = Connectivity();

  void VegasLogInfo(Object message) => print('[I] $message');
  void VegasLogWarn(Object message) => print('[W] $message');
  void VegasLogError(Object message) => print('[E] $message');
}

class VegasHunterNetworkService {
  final VegasHunterLoggerService VegasLogger = VegasHunterLoggerService();

  Future<void> VegasPostJson(
      String url,
      Map<String, dynamic> data,
      ) async {
    try {
      await http.post(
        Uri.parse(url),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(data),
      );
    } catch (error) {
      VegasLogger.VegasLogError('postJson error: $error');
    }
  }
}

// ============================================================================
// Утилита: одновременное сохранение JSON в localStorage и SharedPreferences
// ============================================================================

Future<void> VegasHunterSaveJsonToLocalStorageAndPrefs({
  required InAppWebViewController? controller,
  required String key,
  required Map<String, dynamic> data,
}) async {
  final String jsonString = jsonEncode(data);

  if (controller != null) {
    try {
      await controller.evaluateJavascript(
        source: "localStorage.setItem('$key', JSON.stringify($jsonString));",
      );
    } catch (e, st) {
      VegasHunterLoggerService().VegasLogError(
          'VegasHunterSaveJsonToLocalStorageAndPrefs localStorage error: $e\n$st');
    }
  }

  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonString);
  } catch (e, st) {
    VegasHunterLoggerService().VegasLogError(
        'VegasHunterSaveJsonToLocalStorageAndPrefs prefs error: $e\n$st');
  }
}

// ============================================================================
// Профиль устройства
// ============================================================================

class VegasHunterDeviceProfile {
  String? VegasDeviceId;
  String? VegasSessionId = '';
  String? VegasPlatformName;
  String? VegasOsVersion;
  String? VegasAppVersion;
  String? VegasLanguageCode;
  String? VegasTimezoneName;
  bool VegasPushEnabled = false;

  bool VegasSafeAreaEnabled = false;
  String? VegasSafeAreaColor;

  bool slotCasher = false;

  String? VegasBaseUserAgent;

  Map<String, dynamic>? VegasLastPushData;

  Map<String, dynamic>? VegasSavels;

  Future<void> VegasInitialize() async {
    final DeviceInfoPlugin vegasDeviceInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo vegasAndroidInfo =
      await vegasDeviceInfoPlugin.androidInfo;
      VegasDeviceId = vegasAndroidInfo.id;
      VegasPlatformName = 'android';
      VegasOsVersion = vegasAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo vegasIosInfo = await vegasDeviceInfoPlugin.iosInfo;
      VegasDeviceId = vegasIosInfo.identifierForVendor;
      VegasPlatformName = 'ios';
      VegasOsVersion = vegasIosInfo.systemVersion;
    }

    final PackageInfo vegasPackageInfo = await PackageInfo.fromPlatform();
    VegasAppVersion = vegasPackageInfo.version;
    VegasLanguageCode = Platform.localeName.split('_').first;
    VegasTimezoneName = tz_zone.local.name;
    VegasSessionId = 'test-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> VegasToMap({String? fcmToken}) => <String, dynamic>{
    'fcm_token': fcmToken ?? 'missing_token',
    'device_id': VegasDeviceId ?? 'missing_id',
    'app_name': 'vegasday',
    'instance_id': VegasSessionId ?? 'missing_session',
    'platform': VegasPlatformName ?? 'missing_system',
    'os_version': VegasOsVersion ?? 'missing_build',
    'app_version': '1.4.1' ?? 'missing_app',
    'language': VegasLanguageCode ?? 'en',
    'timezone': VegasTimezoneName ?? 'UTC',
    'push_enabled': VegasPushEnabled,
    'safe_area_native': VegasSafeAreaEnabled,
    'useragent': VegasBaseUserAgent ?? 'unknown_useragent',
    'savels': VegasSavels ?? <String, dynamic>{},
    'fpscashier': slotCasher,
  };
}

// ============================================================================
// AppsFlyer Spy
// ============================================================================

class VegasHunterSpyService {
  appsflyer_core.AppsFlyerOptions? VegasAppsFlyerOptions;
  appsflyer_core.AppsflyerSdk? VegasAppsFlyerSdk;

  String VegasAppsFlyerUid = '';
  String VegasAppsFlyerData = '';

  Map<String, dynamic>? VegasAppsFlyerOneLinkData;

  void VegasStartTracking({VoidCallback? onUpdate}) {
    final appsflyer_core.AppsFlyerOptions vegasConfig =
    appsflyer_core.AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6788030356',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    VegasAppsFlyerOptions = vegasConfig;
    VegasAppsFlyerSdk = appsflyer_core.AppsflyerSdk(vegasConfig);

    VegasAppsFlyerSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    VegasAppsFlyerSdk?.startSDK(
      onSuccess: () =>
          VegasHunterLoggerService().VegasLogInfo('RetroCarAnalyticsSpy started'),
      onError: (int code, String msg) => VegasHunterLoggerService()
          .VegasLogError('RetroCarAnalyticsSpy error $code: $msg'),
    );

    VegasAppsFlyerSdk?.onInstallConversionData((dynamic value) {
      VegasAppsFlyerData = value.toString();
      onUpdate?.call();
    });

    VegasAppsFlyerSdk?.getAppsFlyerUID().then((dynamic value) {
      VegasAppsFlyerUid = value.toString();
      onUpdate?.call();
    });
  }

  void VegasSetOneLinkData(Map<String, dynamic> data) {
    VegasAppsFlyerOneLinkData = data;
    VegasHunterLoggerService()
        .VegasLogInfo('VegasHunterSpyService: OneLink data updated: $data');
  }
}

// ============================================================================
// FCM фон
// ============================================================================

@pragma('vm:entry-point')
Future<void> VegasHunterFcmBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  VegasHunterLoggerService().VegasLogInfo('bg-fcm: ${message.messageId}');
  VegasHunterLoggerService().VegasLogInfo('bg-data: ${message.data}');

  final dynamic vegasLink = message.data['uri'];
  if (vegasLink != null) {
    try {
      final SharedPreferences vegasPrefs = await SharedPreferences.getInstance();
      await vegasPrefs.setString(
        vegasHunterCachedDeepKey,
        vegasLink.toString(),
      );
    } catch (e) {
      VegasHunterLoggerService().VegasLogError('bg-fcm save deep failed: $e');
    }
  }
}

// ============================================================================
// FCM Bridge — токен
// ============================================================================

class VegasHunterFcmBridge {
  final VegasHunterLoggerService VegasLogger = VegasHunterLoggerService();

  static const MethodChannel _tokenChannel =
  MethodChannel('com.example.fcm/token');

  String? VegasToken;
  final List<void Function(String)> VegasTokenWaiters =
  <void Function(String)>[];

  String? get VegasFcmToken => VegasToken;

  Timer? _requestTimer;
  int _requestAttempts = 0;
  final int _maxAttempts = 10;

  VegasHunterFcmBridge() {
    _tokenChannel.setMethodCallHandler((MethodCall vegasCall) async {
      if (vegasCall.method == 'setToken') {
        final String vegasTokenString = vegasCall.arguments as String;
        VegasLogger.VegasLogInfo(
            'VegasHunterFcmBridge: got token from native channel = $vegasTokenString');
        if (vegasTokenString.isNotEmpty) {
          VegasSetToken(vegasTokenString);
        }
      }
    });

    VegasRestoreToken();
    _requestNativeToken();
    _startRequestTimer();
  }

  Future<void> _requestNativeToken() async {
    try {
      VegasLogger.VegasLogInfo('VegasHunterFcmBridge: request native getToken()');
      final String? token =
      await _tokenChannel.invokeMethod<String>('getToken');
      if (token != null && token.isNotEmpty) {
        VegasLogger.VegasLogInfo(
            'VegasHunterFcmBridge: native getToken() returns $token');
        VegasSetToken(token);
      } else {
        VegasLogger.VegasLogWarn(
            'VegasHunterFcmBridge: native getToken() returned empty');
      }
    } catch (e) {
      VegasLogger.VegasLogWarn('VegasHunterFcmBridge: getToken invoke error: $e');
    }
  }

  void _startRequestTimer() {
    _requestTimer?.cancel();
    _requestAttempts = 0;

    _requestTimer = Timer.periodic(const Duration(seconds: 5), (Timer t) async {
      if ((VegasToken ?? '').isNotEmpty) {
        VegasLogger.VegasLogInfo(
            'VegasHunterFcmBridge: token already set, stop request timer');
        t.cancel();
        return;
      }

      if (_requestAttempts >= _maxAttempts) {
        VegasLogger.VegasLogWarn(
            'VegasHunterFcmBridge: max getToken attempts reached, stop timer');
        t.cancel();
        return;
      }

      _requestAttempts++;
      VegasLogger.VegasLogInfo(
          'VegasHunterFcmBridge: retry getToken() attempt #$_requestAttempts');
      await _requestNativeToken();
    });
  }

  Future<void> VegasRestoreToken() async {
    try {
      final SharedPreferences vegasPrefs = await SharedPreferences.getInstance();
      final String? vegasCachedToken =
      vegasPrefs.getString(vegasHunterCachedFcmKey);
      if (vegasCachedToken != null && vegasCachedToken.isNotEmpty) {
        VegasLogger.VegasLogInfo(
            'VegasHunterFcmBridge: restored cached token = $vegasCachedToken');
        VegasSetToken(vegasCachedToken, notify: false);
      }
    } catch (e) {
      VegasLogger.VegasLogError('VegasRestoreToken error: $e');
    }
  }

  Future<void> VegasPersistToken(String newToken) async {
    try {
      final SharedPreferences vegasPrefs = await SharedPreferences.getInstance();
      await vegasPrefs.setString(vegasHunterCachedFcmKey, newToken);
    } catch (e) {
      VegasLogger.VegasLogError('VegasPersistToken error: $e');
    }
  }

  void VegasSetToken(
      String newToken, {
        bool notify = true,
      }) {
    VegasToken = newToken;
    VegasPersistToken(newToken);

    if (notify) {
      for (final void Function(String) vegasCallback
      in List<void Function(String)>.from(VegasTokenWaiters)) {
        try {
          vegasCallback(newToken);
        } catch (error) {
          VegasLogger.VegasLogWarn('fcm waiter error: $error');
        }
      }
      VegasTokenWaiters.clear();
    }
  }

  Future<void> VegasWaitForToken(
      Function(String token) vegasOnToken,
      ) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if ((VegasToken ?? '').isNotEmpty) {
        vegasOnToken(VegasToken!);
        return;
      }

      VegasTokenWaiters.add(vegasOnToken);
    } catch (error) {
      VegasLogger.VegasLogError('VegasWaitForToken error: $error');
    }
  }

  void dispose() {
    _requestTimer?.cancel();
  }
}

// ============================================================================
// Splash / Lobby
// ============================================================================

class VegasHunterLobby extends StatefulWidget {
  const VegasHunterLobby({Key? key}) : super(key: key);

  @override
  State<VegasHunterLobby> createState() => _VegasHunterLobbyState();
}

class _VegasHunterLobbyState extends State<VegasHunterLobby> {
  final VegasHunterFcmBridge VegasFcmBridgeInstance = VegasHunterFcmBridge();
  bool VegasNavigatedOnce = false;
  Timer? VegasFallbackTimer;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    VegasFcmBridgeInstance.VegasWaitForToken((String vegasToken) {
      VegasGoToCasino(vegasToken);
    });

    VegasFallbackTimer = Timer(
      const Duration(seconds: 8),
          () => VegasGoToCasino(''),
    );
  }

  void VegasGoToCasino(String vegasSignal) {
    if (VegasNavigatedOnce) return;
    VegasNavigatedOnce = true;
    VegasFallbackTimer?.cancel();

    Navigator.pushReplacement(
      context,
      MaterialPageRoute<Widget>(
        builder: (BuildContext context) => VegasHunterCasino(VegasSignal: vegasSignal),
      ),
    );
  }

  @override
  void dispose() {
    VegasFallbackTimer?.cancel();
    VegasFcmBridgeInstance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: VLLoaderScreen(),
        ),
      ),
    );
  }
}

// ============================================================================
// ViewModel + Courier
// ============================================================================

class VegasHunterDealerViewModel {
  final VegasHunterDeviceProfile VegasDeviceProfileInstance;
  final VegasHunterSpyService VegasSpyInstance;

  VegasHunterDealerViewModel({
    required this.VegasDeviceProfileInstance,
    required this.VegasSpyInstance,
  });

  Map<String, dynamic> VegasDeviceMap(String? fcmToken) =>
      VegasDeviceProfileInstance.VegasToMap(fcmToken: fcmToken);

  Map<String, dynamic> VegasAppsFlyerPayload(
      String? token, {
        String? deepLink,
      }) {
    final Map<String, dynamic> onelinkData =
        VegasSpyInstance.VegasAppsFlyerOneLinkData ??
            <String, dynamic>{};

    return <String, dynamic>{
      'content': <String, dynamic>{
        'af_data': VegasSpyInstance.VegasAppsFlyerData,
        'af_id': VegasSpyInstance.VegasAppsFlyerUid,
        'fb_app_name': 'vegasday',
        'app_name': 'vegasday',
        'onelink': onelinkData,
        'bundle_identifier': 'com.dayvegas.vegasdayhunt.vegasday',
        'app_version': '1.4.1',
        'apple_id': '6758016333',
        'fcm_token': token ?? 'no_token',
        'device_id': VegasDeviceProfileInstance.VegasDeviceId ?? 'no_device',
        'instance_id':
        VegasDeviceProfileInstance.VegasSessionId ?? 'no_instance',
        'platform': VegasDeviceProfileInstance.VegasPlatformName ?? 'no_type',
        'os_version': VegasDeviceProfileInstance.VegasOsVersion ?? 'no_os',
        'language': VegasDeviceProfileInstance.VegasLanguageCode ?? 'en',
        'timezone': VegasDeviceProfileInstance.VegasTimezoneName ?? 'UTC',
        'push_enabled': VegasDeviceProfileInstance.VegasPushEnabled,
        'useruid': VegasSpyInstance.VegasAppsFlyerUid,
        'safearea': VegasDeviceProfileInstance.VegasSafeAreaEnabled,
        'safearea_color':
        VegasDeviceProfileInstance.VegasSafeAreaColor ?? '',
        'useragent':
        VegasDeviceProfileInstance.VegasBaseUserAgent ?? 'unknown_useragent',
        'push':
        VegasDeviceProfileInstance.VegasLastPushData ?? <String, dynamic>{},
        'deep': deepLink,
        'fpscashier': VegasDeviceProfileInstance.slotCasher,
      },
    };
  }
}

class VegasHunterCourierService {
  final VegasHunterDealerViewModel VegasDealer;
  final InAppWebViewController? Function() VegasGetWebViewController;

  VegasHunterCourierService({
    required this.VegasDealer,
    required this.VegasGetWebViewController,
  });

  Future<InAppWebViewController?> _waitForController({
    Duration timeout = const Duration(seconds: 10),
    Duration interval = const Duration(milliseconds: 200),
  }) async {
    final VegasHunterLoggerService logger = VegasHunterLoggerService();
    final DateTime start = DateTime.now();

    while (DateTime.now().difference(start) < timeout) {
      final InAppWebViewController? c = VegasGetWebViewController();
      if (c != null) {
        return c;
      }
      await Future<void>.delayed(interval);
    }

    logger.VegasLogWarn('_waitForController: timeout, controller is still null');
    return null;
  }

  Future<void> VegasPutDeviceToLocalStorage(String? token) async {
    final InAppWebViewController? vegasController = await _waitForController();
    if (vegasController == null) return;

    final Map<String, dynamic> vegasMap = VegasDealer.VegasDeviceMap(token);
    VegasHunterLoggerService().VegasLogInfo("applocal (${jsonEncode(vegasMap)});");

    await VegasHunterSaveJsonToLocalStorageAndPrefs(
      controller: vegasController,
      key: 'app_data',
      data: vegasMap,
    );
  }

  Future<void> VegasSendRawToPage(
      String? token, {
        String? deepLink,
      }) async {
    final InAppWebViewController? vegasController = await _waitForController();
    if (vegasController == null) return;

    final Map<String, dynamic> vegasPayload =
    VegasDealer.VegasAppsFlyerPayload(token, deepLink: deepLink);

    final String vegasJsonString = jsonEncode(vegasPayload);

    VegasHunterLoggerService().VegasLogInfo('SendRawData: $vegasJsonString');

    final String jsSafeJson = jsonEncode(vegasJsonString);
    final String jsCode = 'sendRawData($jsSafeJson);';

    try {
      await vegasController.evaluateJavascript(source: jsCode);
    } catch (e, st) {
      VegasHunterLoggerService()
          .VegasLogError('VegasSendRawToPage evaluateJavascript error: $e\n$st');
    }
  }
}

// ============================================================================
// Статистика
// ============================================================================

Future<String> VegasHunterResolveFinalUrl(
    String startUrl, {
      int maxHops = 10,
    }) async {
  final HttpClient vegasHttpClient = HttpClient();

  try {
    Uri vegasCurrentUri = Uri.parse(startUrl);

    for (int vegasIndex = 0; vegasIndex < maxHops; vegasIndex++) {
      final HttpClientRequest vegasRequest =
      await vegasHttpClient.getUrl(vegasCurrentUri);
      vegasRequest.followRedirects = false;
      final HttpClientResponse vegasResponse = await vegasRequest.close();

      if (vegasResponse.isRedirect) {
        final String? vegasLocationHeader =
        vegasResponse.headers.value(HttpHeaders.locationHeader);
        if (vegasLocationHeader == null || vegasLocationHeader.isEmpty) {
          break;
        }

        final Uri vegasNextUri = Uri.parse(vegasLocationHeader);
        vegasCurrentUri = vegasNextUri.hasScheme
            ? vegasNextUri
            : vegasCurrentUri.resolveUri(vegasNextUri);
        continue;
      }

      return vegasCurrentUri.toString();
    }

    return vegasCurrentUri.toString();
  } catch (error) {
    print('goldenLuxuryResolveFinalUrl error: $error');
    return startUrl;
  } finally {
    vegasHttpClient.close(force: true);
  }
}

Future<void> VegasHunterPostStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appSid,
  int? firstPageLoadTs,
}) async {
  try {
    final String vegasResolvedUrl = await VegasHunterResolveFinalUrl(url);

    final Map<String, dynamic> vegasPayload = <String, dynamic>{
      'event': event,
      'timestart': timeStart,
      'timefinsh': timeFinish,
      'url': vegasResolvedUrl,
      'appleID': '6788030356',
      'open_count': '$appSid/$timeStart',
    };

    print('goldenLuxuryStat $vegasPayload');

    final http.Response vegasResponse = await http.post(
      Uri.parse('$vegasHunterStatEndpoint/$appSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(vegasPayload),
    );

    print(
        'goldenLuxuryStat resp=${vegasResponse.statusCode} body=${vegasResponse.body}');
  } catch (error) {
    print('goldenLuxuryPostStat error: $error');
  }
}

// ============================================================================
// Открытие неизвестных кастомных схем (otpauth и т.п.) во внешнем приложении
// ============================================================================

Future<bool> VegasHunterTryOpenUnknownSchemeExternally(Uri uri) async {
  try {
    final bool can = await canLaunchUrl(uri);
    if (!can) {
      print('VegasHunterTryOpenUnknownSchemeExternally: no handler for $uri');
      return false;
    }
    final bool ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    print('VegasHunterTryOpenUnknownSchemeExternally: launched=$ok uri=$uri');
    return ok;
  } catch (e) {
    print('VegasHunterTryOpenUnknownSchemeExternally error: $e; uri=$uri');
    return false;
  }
}

bool VegasHunterIsCancelledLoadError({String? description, dynamic type}) {
  final String desc = (description ?? '').toLowerCase();
  final String typeString = (type?.toString() ?? '').toLowerCase();
  return desc.contains('-999') ||
      desc.contains('cancelled') ||
      desc.contains('canceled') ||
      typeString.contains('cancelled') ||
      typeString.contains('canceled');
}

// ============================================================================
// Банковские утилиты
// ============================================================================

bool VegasHunterIsJackpotScheme(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  return kJackpotSchemes.contains(scheme);
}

bool VegasHunterIsJackpotDomain(Uri uri) {
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;

  for (final String bank in kJackpotDomains) {
    final String bankHost = bank.toLowerCase();
    if (host == bankHost || host.endsWith('.$bankHost')) {
      return true;
    }
  }
  return false;
}

Future<bool> VegasHunterOpenJackpot(Uri uri) async {
  try {
    if (VegasHunterIsJackpotScheme(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }

    if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        VegasHunterIsJackpotDomain(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }
  } catch (e) {
    print('VegasHunterOpenJackpot error: $e; url=$uri');
  }
  return false;
}

// ============================================================================
// Главный WebView — Casino
// ============================================================================

class VegasHunterCasino extends StatefulWidget {
  final String? VegasSignal;

  const VegasHunterCasino({super.key, required this.VegasSignal});

  @override
  State<VegasHunterCasino> createState() => _VegasHunterCasinoState();
}

class _VegasHunterCasinoState extends State<VegasHunterCasino> with WidgetsBindingObserver {
  InAppWebViewController? VegasWebViewController;

  InAppWebViewController? VegasPopupWebViewController;
  bool _isPopupVisible = false;
  String? _popupUrl;
  CreateWindowAction? _popupCreateAction;

  bool _popupCanGoBack = false;
  String? _popupCurrentUrl;

  bool _isOpeningExternalNewTab = false;
  final Set<String> _handledNewTabUrls = <String>{};

  Timer? _parentInstallTimer;
  Timer? _popupInstallTimer;

  final String VegasHomeUrl = 'https://servlog.vegasday.blog/';

  int VegasWebViewKeyCounter = 0;
  DateTime? VegasSleepAt;
  bool VegasVeilVisible = false;
  double VegasWarmProgress = 0.0;
  late Timer VegasWarmTimer;
  final int VegasWarmSeconds = 6;
  bool VegasCoverVisible = true;

  bool VegasLoadedOnceSent = false;
  int? VegasFirstPageTimestamp;

  VegasHunterCourierService? VegasCourier;
  VegasHunterDealerViewModel? VegasDealerInstance;

  String VegasCurrentUrl = '';
  int VegasStartLoadTimestamp = 0;

  final VegasHunterDeviceProfile VegasDeviceProfileInstance = VegasHunterDeviceProfile();
  final VegasHunterSpyService VegasSpyInstance =
  VegasHunterSpyService();

  final Set<String> VegasSpecialSchemes = <String>{
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

  final Set<String> VegasExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'm.me',
    'signal.me',
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

  String? VegasDeepLinkFromPush;

  String? _baseUserAgent;
  String _currentUserAgent = "";
  String? _currentUrl;

  String? _serverUserAgent;

  bool _safeAreaEnabled = false;
  Color _safeAreaBackgroundColor = const Color(0xFF000000);

  bool _startupSendRawDone = false;

  String? _pendingLoadedJs;

  bool _loadedJsExecutedOnce = false;

  bool _isInGoogleAuth = false;

  List<String> _buttonWhitelist = <String>[];
  bool _showBackButton = false;

  bool _backButtonHiddenAfterTap = false;

  bool _isCurrentlyOnGoogle = false;

  static const MethodChannel _appsFlyerDeepLinkChannel =
  MethodChannel('appsflyer_deeplink_channel');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VegasFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;
    _currentUrl = VegasHomeUrl;

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          VegasCoverVisible = false;
        });
      }
    });

    Future<void>.delayed(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() {
        VegasVeilVisible = true;
      });
    });

    _bindPushChannelFromAppDelegate();
    _bindAppsFlyerDeepLinkChannel();
    VegasBootCasino();
  }

  bool _isAboutBlankUrl(String? value) {
    final String u = (value ?? '').trim().toLowerCase();
    return u.isEmpty || u == 'about:blank' || u.startsWith('about:blank');
  }

  bool _isAboutBlankUri(Uri? uri) => _isAboutBlankUrl(uri?.toString());

  void _bindAppsFlyerDeepLinkChannel() {
    _appsFlyerDeepLinkChannel.setMethodCallHandler(
          (MethodCall call) async {
        if (call.method == 'onDeepLink') {
          try {
            final dynamic args = call.arguments;

            Map<String, dynamic> payload;

            print(" Data Deepl link ${args.toString()}");
            if (args is Map) {
              payload = Map<String, dynamic>.from(args as Map);
            } else if (args is String) {
              payload = jsonDecode(args) as Map<String, dynamic>;
            } else {
              payload = <String, dynamic>{'raw': args.toString()};
            }

            VegasHunterLoggerService().VegasLogInfo(
              'AppsFlyer onDeepLink from iOS: $payload',
            );

            final dynamic raw = payload['raw'];
            if (raw is Map) {
              final Map<String, dynamic> normalized =
              Map<String, dynamic>.from(raw as Map);

              print("One Link Data $normalized");
              VegasSpyInstance.VegasSetOneLinkData(normalized);

              _handleOneLinkDeepNavigation(normalized);
            } else {
              VegasSpyInstance.VegasSetOneLinkData(payload);
              _handleOneLinkDeepNavigation(payload);
            }
          } catch (e, st) {
            VegasHunterLoggerService()
                .VegasLogError('Error in onDeepLink handler: $e\n$st');
          }
        }
      },
    );
  }

  /// Обработка OneLink deep link — навигация внутри WebView, а не во внешний браузер
  void _handleOneLinkDeepNavigation(Map<String, dynamic> data) {
    try {
      String? targetUrl;

      if (data.containsKey('deep_link_value') &&
          data['deep_link_value'] != null) {
        final String dlv = data['deep_link_value'].toString().trim();
        if (dlv.startsWith('http://') || dlv.startsWith('https://')) {
          targetUrl = dlv;
        }
      }

      if (targetUrl == null &&
          data.containsKey('af_dp') &&
          data['af_dp'] != null) {
        final String afDp = data['af_dp'].toString().trim();
        if (afDp.startsWith('http://') || afDp.startsWith('https://')) {
          targetUrl = afDp;
        }
      }

      if (targetUrl == null &&
          data.containsKey('link') &&
          data['link'] != null) {
        final String link = data['link'].toString().trim();
        if (link.startsWith('http://') || link.startsWith('https://')) {
          targetUrl = link;
        }
      }

      if (targetUrl == null &&
          data.containsKey('clickURL') &&
          data['clickURL'] != null) {
        final String clickUrl = data['clickURL'].toString().trim();
        if (clickUrl.startsWith('http://') || clickUrl.startsWith('https://')) {
          targetUrl = clickUrl;
        }
      }

      if (targetUrl != null && targetUrl.isNotEmpty) {
        VegasHunterLoggerService().VegasLogInfo(
            'OneLink deep navigation: loading $targetUrl in WebView');
        VegasDeepLinkFromPush = targetUrl;

        Future<void>.delayed(const Duration(milliseconds: 500), () {
          VegasNavigateToUri(targetUrl!);
        });
      } else {
        VegasHunterLoggerService().VegasLogInfo(
            'OneLink deep navigation: no target URL found in data, '
                'sending data to page via sendRawData');
      }
    } catch (e, st) {
      VegasHunterLoggerService()
          .VegasLogError('_handleOneLinkDeepNavigation error: $e\n$st');
    }
  }

  void _bindPushChannelFromAppDelegate() {
    const MethodChannel pushChannel = MethodChannel('com.example.fcm/push');

    pushChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'setPushData') {
        try {
          Map<String, dynamic> pushData;
          if (call.arguments is Map) {
            pushData = Map<String, dynamic>.from(call.arguments);
            print("Get Push Data $pushData");
          } else if (call.arguments is String) {
            pushData =
            jsonDecode(call.arguments as String) as Map<String, dynamic>;
          } else {
            pushData = <String, dynamic>{'raw': call.arguments.toString()};
          }

          VegasHunterLoggerService()
              .VegasLogInfo('Got push data from AppDelegate: $pushData');

          VegasDeviceProfileInstance.VegasLastPushData = pushData;

          final dynamic uriRaw = pushData['uri'] ?? pushData['deep_link'];
          if (uriRaw != null && uriRaw.toString().isNotEmpty) {
            final String u = uriRaw.toString();
            VegasDeepLinkFromPush = u;
            await VegasSaveCachedDeep(u);
          }
        } catch (e, st) {
          VegasHunterLoggerService()
              .VegasLogError('setPushData handler error: $e\n$st');
        }
      }
    });
  }

  bool _isGoogleUrl(Uri uri) {
    final String full = uri.toString().toLowerCase();
    return full.contains('google.com') ||
        full.contains('accounts.google.') ||
        full.contains('googleusercontent.com') ||
        full.contains('gstatic.com');
  }

  Future<void> _applyGoogleUserAgent() async {
    if (VegasWebViewController == null) return;

    const String googleUa = 'random';

    if (_currentUserAgent == googleUa) {
      VegasHunterLoggerService()
          .VegasLogInfo('[UA] Already set to "random" for Google, skip');
      return;
    }

    VegasHunterLoggerService()
        .VegasLogInfo('[UA] Applying GOOGLE User-Agent: $googleUa');

    try {
      await VegasWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      _currentUserAgent = googleUa;
      _isCurrentlyOnGoogle = true;
      print('[UA] GOOGLE WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      VegasHunterLoggerService()
          .VegasLogError('Error setting Google User-Agent: $e');
    }
  }

  Future<void> _applyGoogleUserAgentForPopup() async {
    if (VegasPopupWebViewController == null) return;

    const String googleUa = 'random';

    VegasHunterLoggerService()
        .VegasLogInfo('[UA] Applying GOOGLE User-Agent to POPUP: $googleUa');

    try {
      await VegasPopupWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      print('[UA] GOOGLE POPUP USER AGENT: $googleUa');
    } catch (e) {
      VegasHunterLoggerService()
          .VegasLogError('Error setting Google User-Agent for popup: $e');
    }
  }

  Future<void> _updateUserAgentFromServerPayload(
      Map<dynamic, dynamic> root) async {
    String? fullua;
    String? uatail;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['fullua'] != null &&
          content['fullua'].toString().trim().isNotEmpty) {
        fullua = content['fullua'].toString().trim();
      }
      if (content['uatail'] != null &&
          content['uatail'].toString().trim().isNotEmpty) {
        uatail = content['uatail'].toString().trim();
      }
    }

    if (fullua == null &&
        root['fullua'] != null &&
        root['fullua'].toString().trim().isNotEmpty) {
      fullua = root['fullua'].toString().trim();
    }
    if (uatail == null &&
        root['uatail'] != null &&
        root['uatail'].toString().trim().isNotEmpty) {
      uatail = root['uatail'].toString().trim();
    }

    if (uatail == null) {
      final dynamic adata = root['adata'];
      if (adata is Map &&
          adata['uatail'] != null &&
          adata['uatail'].toString().trim().isNotEmpty) {
        uatail = adata['uatail'].toString().trim();
      }
    }

    await _applyUserAgent(fullua: fullua, uatail: uatail);
  }

  Future<void> _applyUserAgent({String? fullua, String? uatail}) async {
    if (VegasWebViewController == null) return;

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      try {
        final ua = await VegasWebViewController!.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (ua is String && ua.trim().isNotEmpty) {
          _baseUserAgent = ua.trim();
          _currentUserAgent = _baseUserAgent!;
          VegasDeviceProfileInstance.VegasBaseUserAgent = _baseUserAgent;
          VegasHunterLoggerService()
              .VegasLogInfo('Base User-Agent detected: $_baseUserAgent');
        }
      } catch (e) {
        VegasHunterLoggerService()
            .VegasLogWarn('Failed to get base userAgent from JS: $e');
      }
    }

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      VegasHunterLoggerService()
          .VegasLogWarn('Base User-Agent is still null/empty, skip UA update');
      return;
    }

    VegasHunterLoggerService().VegasLogInfo(
        'Server UA payload: fullua="$fullua", uatail="$uatail", base="$_baseUserAgent"');

    String newUa;
    if (fullua != null && fullua.trim().isNotEmpty) {
      newUa = fullua.trim();
    } else if (uatail != null && uatail.trim().isNotEmpty) {
      newUa = "${_baseUserAgent!}/${uatail.trim()}";
    } else {
      newUa = "${_baseUserAgent!}";
    }

    _serverUserAgent = newUa;
    VegasHunterLoggerService()
        .VegasLogInfo('Server UA calculated and stored: $_serverUserAgent');
  }

  Future<void> _applyNormalUserAgentIfNeeded() async {
    if (VegasWebViewController == null) return;

    if (_isCurrentlyOnGoogle) {
      VegasHunterLoggerService().VegasLogInfo(
          '[UA] Currently on Google page, keeping "random" UA');
      return;
    }

    final String targetUa = _serverUserAgent ?? _baseUserAgent ?? 'random';

    if (targetUa == _currentUserAgent) {
      VegasHunterLoggerService()
          .VegasLogInfo('Normal UA unchanged, keeping: $_currentUserAgent');
      return;
    }

    VegasHunterLoggerService()
        .VegasLogInfo('Applying NORMAL WebView User-Agent: $targetUa');

    try {
      await VegasWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      print('[UA] NORMAL WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      VegasHunterLoggerService()
          .VegasLogError('Error while setting normal User-Agent "$targetUa": $e');
    }
  }

  Future<void> _switchUserAgentForUrl(Uri? uri) async {
    if (uri == null) return;

    if (_isGoogleUrl(uri)) {
      _isCurrentlyOnGoogle = true;
      await _applyGoogleUserAgent();
    } else {
      if (_isCurrentlyOnGoogle) {
        _isCurrentlyOnGoogle = false;
      }
      await _applyNormalUserAgentIfNeeded();
    }
  }

  Future<void> vegasPrintJsUserAgent() async {
    if (VegasWebViewController == null) return;

    try {
      final ua = await VegasWebViewController!.evaluateJavascript(
        source: "navigator.userAgent",
      );

      if (ua is String) {
        print('[JS UA] navigator.userAgent = $ua');
      } else {
        print('[JS UA] navigator.userAgent (non-string) = $ua');
      }
    } catch (e, st) {
      print('Error reading navigator.userAgent: $e\n$st');
    }
  }

  Future<void> vegasDebugPrintCurrentUserAgent() async {
    VegasHunterLoggerService()
        .VegasLogInfo('[STATE UA] _currentUserAgent = $_currentUserAgent');
    await vegasPrintJsUserAgent();
  }

  Future<void> VegasLoadLoadedFlag() async {
    final SharedPreferences vegasPrefs = await SharedPreferences.getInstance();
    VegasLoadedOnceSent = vegasPrefs.getBool(vegasHunterLoadedOnceKey) ?? false;
  }

  Future<void> VegasSaveLoadedFlag() async {
    final SharedPreferences vegasPrefs = await SharedPreferences.getInstance();
    await vegasPrefs.setBool(vegasHunterLoadedOnceKey, true);
    VegasLoadedOnceSent = true;
  }

  Future<void> VegasLoadCachedDeep() async {
    try {
      final SharedPreferences vegasPrefs = await SharedPreferences.getInstance();
      final String? vegasCached = vegasPrefs.getString(vegasHunterCachedDeepKey);
      if ((vegasCached ?? '').isNotEmpty) {
        VegasDeepLinkFromPush = vegasCached;
      }
    } catch (_) {}
  }

  Future<void> VegasSaveCachedDeep(String uri) async {
    try {
      final SharedPreferences vegasPrefs = await SharedPreferences.getInstance();
      await vegasPrefs.setString(vegasHunterCachedDeepKey, uri);
    } catch (_) {}
  }

  Future<void> VegasSendLoadedOnce({
    required String url,
    required int timestart,
  }) async {
    if (VegasLoadedOnceSent) return;

    final int vegasNow = DateTime.now().millisecondsSinceEpoch;

    await VegasHunterPostStat(
      event: 'Loaded',
      timeStart: timestart,
      timeFinish: vegasNow,
      url: url,
      appSid: VegasSpyInstance.VegasAppsFlyerUid,
      firstPageLoadTs: VegasFirstPageTimestamp,
    );

    await VegasSaveLoadedFlag();
  }

  void VegasBootCasino() {
    VegasStartWarmProgress();
    VegasWireFcmHandlers();
    VegasSpyInstance.VegasStartTracking(
      onUpdate: () => setState(() {}),
    );
    VegasBindNotificationTap();
    VegasPrepareDeviceProfile();
  }

  void VegasWireFcmHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage vegasMessage) async {
      final dynamic vegasLink = vegasMessage.data['uri'];
      if (vegasLink != null) {
        final String vegasUri = vegasLink.toString();
        VegasDeepLinkFromPush = vegasUri;
        await VegasSaveCachedDeep(vegasUri);
      } else {
        VegasResetHomeAfterDelay();
      }
    });

    FirebaseMessaging.onMessageOpenedApp
        .listen((RemoteMessage vegasMessage) async {
      final dynamic vegasLink = vegasMessage.data['uri'];
      if (vegasLink != null) {
        final String vegasUri = vegasLink.toString();
        VegasDeepLinkFromPush = vegasUri;
        await VegasSaveCachedDeep(vegasUri);

        VegasNavigateToUri(vegasUri);

        await VegasPushDeviceInfo();
        await VegasPushAppsFlyerData();
      } else {
        VegasResetHomeAfterDelay();
      }
    });
  }

  void VegasBindNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onNotificationTap') {
        final Map<String, dynamic> vegasPayload =
        Map<String, dynamic>.from(call.arguments);
        final String? vegasUriRaw = vegasPayload['uri']?.toString();

        if (vegasUriRaw != null &&
            vegasUriRaw.isNotEmpty &&
            !vegasUriRaw.contains('Нет URI')) {
          final String vegasUri = vegasUriRaw;
          VegasDeepLinkFromPush = vegasUri;
          await VegasSaveCachedDeep(vegasUri);

          if (!context.mounted) return;

          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext context) => VegasHunterTableView(vegasUri),
            ),
                (Route<dynamic> route) => false,
          );

          await VegasPushDeviceInfo();
          await VegasPushAppsFlyerData();
        }
      }
    });
  }

  Future<void> VegasPrepareDeviceProfile() async {
    try {
      await VegasDeviceProfileInstance.VegasInitialize();

      final FirebaseMessaging vegasMessaging = FirebaseMessaging.instance;
      final NotificationSettings vegasSettings =
      await vegasMessaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      VegasDeviceProfileInstance.VegasPushEnabled =
          vegasSettings.authorizationStatus ==
              AuthorizationStatus.authorized ||
              vegasSettings.authorizationStatus ==
                  AuthorizationStatus.provisional;

      await VegasLoadLoadedFlag();
      await VegasLoadCachedDeep();

      VegasDealerInstance = VegasHunterDealerViewModel(
        VegasDeviceProfileInstance: VegasDeviceProfileInstance,
        VegasSpyInstance: VegasSpyInstance,
      );

      VegasCourier = VegasHunterCourierService(
        VegasDealer: VegasDealerInstance!,
        VegasGetWebViewController: () => VegasWebViewController,
      );
    } catch (error) {
      VegasHunterLoggerService().VegasLogError('prepareDeviceProfile fail: $error');
    }
  }

  void VegasNavigateToUri(String link) async {
    try {
      await VegasWebViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(link)),
      );
    } catch (error) {
      VegasHunterLoggerService().VegasLogError('navigate error: $error');
    }
  }

  void VegasResetHomeAfterDelay() {
    Future<void>.delayed(const Duration(seconds: 3), () {
      try {
        VegasWebViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(VegasHomeUrl)),
        );
      } catch (_) {}
    });
  }

  String? _resolveTokenForShip() {
    if (widget.VegasSignal != null && widget.VegasSignal!.isNotEmpty) {
      return widget.VegasSignal;
    }
    return null;
  }

  Future<void> _sendAllDataToPageTwice() async {
    await VegasPushDeviceInfo();

    Future<void>.delayed(const Duration(seconds: 6), () async {
      await VegasPushDeviceInfo();
      await VegasPushAppsFlyerData();
    });
  }

  Future<void> VegasPushDeviceInfo() async {
    final String? vegasToken = _resolveTokenForShip();

    try {
      await VegasCourier?.VegasPutDeviceToLocalStorage(vegasToken);
    } catch (error) {
      VegasHunterLoggerService().VegasLogError('pushDeviceInfo error: $error');
    }
  }

  Future<void> VegasPushAppsFlyerData() async {
    final String? vegasToken = _resolveTokenForShip();

    try {
      await VegasCourier?.VegasSendRawToPage(
        vegasToken,
        deepLink: VegasDeepLinkFromPush,
      );
    } catch (error) {
      VegasHunterLoggerService().VegasLogError('pushAppsFlyerData error: $error');
    }
  }

  void VegasStartWarmProgress() {
    int vegasTick = 0;
    VegasWarmProgress = 0.0;

    VegasWarmTimer =
        Timer.periodic(const Duration(milliseconds: 100), (Timer timer) {
          if (!mounted) return;

          setState(() {
            vegasTick++;
            VegasWarmProgress = vegasTick / (VegasWarmSeconds * 10);

            if (VegasWarmProgress >= 1.0) {
              VegasWarmProgress = 1.0;
              VegasWarmTimer.cancel();
            }
          });
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      VegasSleepAt = DateTime.now();
    }

    if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS && VegasSleepAt != null) {
        final DateTime vegasNow = DateTime.now();
        final Duration vegasDrift = vegasNow.difference(VegasSleepAt!);

        if (vegasDrift > const Duration(minutes: 25)) {
          VegasReboardCasino();
        }
      }
      VegasSleepAt = null;
    }
  }

  void VegasReboardCasino() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) =>
              VegasHunterCasino(VegasSignal: widget.VegasSignal),
        ),
            (Route<dynamic> route) => false,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    VegasWarmTimer.cancel();

    _parentInstallTimer?.cancel();
    _popupInstallTimer?.cancel();

    VegasWebViewController = null;
    VegasPopupWebViewController = null;

    super.dispose();
  }

  bool VegasIsBareEmail(Uri uri) {
    final String vegasScheme = uri.scheme;
    if (vegasScheme.isNotEmpty) return false;
    final String vegasRaw = uri.toString();
    return vegasRaw.contains('@') && !vegasRaw.contains(' ');
  }

  Uri VegasToMailto(Uri uri) {
    final String vegasFull = uri.toString();
    final List<String> vegasParts = vegasFull.split('?');
    final String vegasEmail = vegasParts.first;
    final Map<String, String> vegasQueryParams = vegasParts.length > 1
        ? Uri.splitQueryString(vegasParts[1])
        : <String, String>{};

    return Uri(
      scheme: 'mailto',
      path: vegasEmail,
      queryParameters: vegasQueryParams.isEmpty ? null : vegasQueryParams,
    );
  }

  Future<bool> VegasOpenMailExternal(Uri mailto) async {
    try {
      final String scheme = mailto.scheme.toLowerCase();
      final String path = mailto.path.toLowerCase();

      VegasHunterLoggerService().VegasLogInfo(
          'VegasOpenMailExternal: scheme=$scheme path=$path uri=$mailto');

      if (scheme != 'mailto') {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        VegasHunterLoggerService()
            .VegasLogInfo('VegasOpenMailExternal: non-mailto result=$ok');
        return ok;
      }

      final bool can = await canLaunchUrl(mailto);
      VegasHunterLoggerService()
          .VegasLogInfo('VegasOpenMailExternal: canLaunchUrl(mailto) = $can');

      if (can) {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        VegasHunterLoggerService()
            .VegasLogInfo('VegasOpenMailExternal: externalApplication result=$ok');
        if (ok) return true;
      }

      VegasHunterLoggerService().VegasLogWarn(
          'VegasOpenMailExternal: no native handler for mailto, fallback to Gmail Web');
      final Uri gmailUri = VegasGmailizeMailto(mailto);
      final bool webOk = await VegasOpenWeb(gmailUri);
      VegasHunterLoggerService()
          .VegasLogInfo('VegasOpenMailExternal: Gmail Web fallback result=$webOk');
      return webOk;
    } catch (e, st) {
      VegasHunterLoggerService()
          .VegasLogError('VegasOpenMailExternal error: $e\n$st; url=$mailto');
      return false;
    }
  }

  Future<bool> VegasOpenMailWeb(Uri mailto) async {
    final Uri vegasGmailUri = VegasGmailizeMailto(mailto);
    return VegasOpenWeb(vegasGmailUri);
  }

  Uri VegasGmailizeMailto(Uri mailUri) {
    final Map<String, String> vegasQueryParams = mailUri.queryParameters;

    final Map<String, String> vegasParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (mailUri.path.isNotEmpty) 'to': mailUri.path,
      if ((vegasQueryParams['subject'] ?? '').isNotEmpty)
        'su': vegasQueryParams['subject']!,
      if ((vegasQueryParams['body'] ?? '').isNotEmpty)
        'body': vegasQueryParams['body']!,
      if ((vegasQueryParams['cc'] ?? '').isNotEmpty)
        'cc': vegasQueryParams['cc']!,
      if ((vegasQueryParams['bcc'] ?? '').isNotEmpty)
        'bcc': vegasQueryParams['bcc']!,
    };

    return Uri.https('mail.google.com', '/mail/', vegasParams);
  }

  bool VegasIsPlatformLink(Uri uri) {
    final String vegasScheme = uri.scheme.toLowerCase();
    if (VegasSpecialSchemes.contains(vegasScheme)) {
      return true;
    }

    if (vegasScheme == 'http' || vegasScheme == 'https') {
      final String vegasHost = uri.host.toLowerCase();

      if (VegasExternalHosts.contains(vegasHost)) {
        return true;
      }

      if (vegasHost.endsWith('t.me')) return true;
      if (vegasHost.endsWith('wa.me')) return true;
      if (vegasHost.endsWith('m.me')) return true;
      if (vegasHost.endsWith('signal.me')) return true;
      if (vegasHost.endsWith('facebook.com')) return true;
      if (vegasHost.endsWith('instagram.com')) return true;
      if (vegasHost.endsWith('twitter.com')) return true;
      if (vegasHost.endsWith('x.com')) return true;
    }

    return false;
  }

  String VegasDigitsOnly(String source) =>
      source.replaceAll(RegExp(r'[^0-9+]'), '');

  Uri VegasHttpizePlatformUri(Uri uri) {
    final String vegasScheme = uri.scheme.toLowerCase();

    if (vegasScheme == 'tg' || vegasScheme == 'telegram') {
      final Map<String, String> vegasQp = uri.queryParameters;
      final String? vegasDomain = vegasQp['domain'];

      if (vegasDomain != null && vegasDomain.isNotEmpty) {
        return Uri.https(
          't.me',
          '/$vegasDomain',
          <String, String>{
            if (vegasQp['start'] != null) 'start': vegasQp['start']!,
          },
        );
      }

      final String vegasPath = uri.path.isNotEmpty ? uri.path : '';

      return Uri.https(
        't.me',
        '/$vegasPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if ((vegasScheme == 'http' || vegasScheme == 'https') &&
        uri.host.toLowerCase().endsWith('t.me')) {
      return uri;
    }

    if (vegasScheme == 'viber') {
      return uri;
    }

    if (vegasScheme == 'whatsapp') {
      final Map<String, String> vegasQp = uri.queryParameters;
      final String? vegasPhone = vegasQp['phone'];
      final String? vegasText = vegasQp['text'];

      if (vegasPhone != null && vegasPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${VegasDigitsOnly(vegasPhone)}',
          <String, String>{
            if (vegasText != null && vegasText.isNotEmpty) 'text': vegasText,
          },
        );
      }

      return Uri.https(
        'wa.me',
        '/',
        <String, String>{
          if (vegasText != null && vegasText.isNotEmpty) 'text': vegasText,
        },
      );
    }

    if ((vegasScheme == 'http' || vegasScheme == 'https') &&
        (uri.host.toLowerCase().endsWith('wa.me') ||
            uri.host.toLowerCase().endsWith('whatsapp.com'))) {
      return uri;
    }

    if (vegasScheme == 'skype') {
      return uri;
    }

    if (vegasScheme == 'fb-messenger') {
      final String vegasPath =
      uri.pathSegments.isNotEmpty ? uri.pathSegments.join('/') : '';
      final Map<String, String> vegasQp = uri.queryParameters;

      final String vegasId = vegasQp['id'] ?? vegasQp['user'] ?? vegasPath;

      if (vegasId.isNotEmpty) {
        return Uri.https(
          'm.me',
          '/$vegasId',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return Uri.https(
        'm.me',
        '/',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if (vegasScheme == 'sgnl') {
      final Map<String, String> vegasQp = uri.queryParameters;
      final String? vegasPhone = vegasQp['phone'];
      final String? vegasUsername = vegasQp['username'];

      if (vegasPhone != null && vegasPhone.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#p/${VegasDigitsOnly(vegasPhone)}',
        );
      }

      if (vegasUsername != null && vegasUsername.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#u/$vegasUsername',
        );
      }

      final String vegasPath = uri.pathSegments.join('/');
      if (vegasPath.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/$vegasPath',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return uri;
    }

    if (vegasScheme == 'tel') {
      return Uri.parse('tel:${VegasDigitsOnly(uri.path)}');
    }

    if (vegasScheme == 'mailto') {
      return uri;
    }

    if (vegasScheme == 'bnl') {
      final String vegasNewPath = uri.path.isNotEmpty ? uri.path : '';
      return Uri.https(
        'bnl.com',
        '/$vegasNewPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    return uri;
  }

  Future<bool> VegasOpenWeb(Uri uri) async {
    try {
      if (await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }

      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      try {
        return await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }

  Future<bool> VegasOpenExternal(Uri uri) async {
    try {
      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      return false;
    }
  }

  void VegasHandleServerSavedata(String savedata) {
    print('onServerResponse savedata: $savedata');

    if(savedata=='false'){
      Navigator.pushReplacement(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) =>
              AssetWebViewScreen(assetPath: 'assets/vegasday.html',),
        ),
      );
    }
  }

  Color _parseHexColor(String hex) {
    String value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) {
      value = 'FF$value';
    }
    final intColor = int.tryParse(value, radix: 16) ?? 0xFF000000;
    return Color(intColor);
  }

  Future<void> _updateAppDataInLocalStorageFromProfile() async {
    final InAppWebViewController? controller = VegasWebViewController;
    if (controller == null) return;

    final String? token = _resolveTokenForShip();
    final Map<String, dynamic> map =
    VegasDeviceProfileInstance.VegasToMap(fcmToken: token);

    VegasHunterLoggerService()
        .VegasLogInfo('updateAppDataFromProfile: ${jsonEncode(map)}');

    await VegasHunterSaveJsonToLocalStorageAndPrefs(
      controller: controller,
      key: 'app_data',
      data: map,
    );
  }

  void _updateExtraDataFromServerPayload(Map<dynamic, dynamic> root) {
    try {
      final dynamic adataRaw = root['adata'];
      if (adataRaw is Map) {
        final Map adata = adataRaw;

        final dynamic buttonswlRaw = adata['buttonswl'];
        if (buttonswlRaw is List) {
          final List<String> list = buttonswlRaw
              .where((e) => e != null)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          setState(() {
            _buttonWhitelist = list;
          });
          VegasHunterLoggerService()
              .VegasLogInfo('buttonswl updated: $_buttonWhitelist');
          _updateBackButtonVisibility();
        }

        if (adata.containsKey('fpscashier')) {
          final dynamic fpsRaw = adata['fpscashier'];
          bool? fpsValue;

          if (fpsRaw is bool) {
            fpsValue = fpsRaw;
          } else if (fpsRaw is num) {
            fpsValue = fpsRaw != 0;
          } else if (fpsRaw is String) {
            final String v = fpsRaw.toLowerCase().trim();
            if (v == 'true' || v == '1' || v == 'yes') fpsValue = true;
            if (v == 'false' || v == '0' || v == 'no') fpsValue = false;
          }

          if (fpsValue != null) {
            final bool old = VegasDeviceProfileInstance.slotCasher;
            VegasDeviceProfileInstance.slotCasher = fpsValue;
            VegasHunterLoggerService().VegasLogInfo(
                'fpscashier updated from server payload: $fpsValue');

            _updateAppDataInLocalStorageFromProfile();

            if (!old && fpsValue && VegasWebViewController != null) {
              VegasHunterLoggerService().VegasLogInfo(
                  'fpscashier switched to true, installing JS hooks now');
              _scheduleSafeInstall(VegasWebViewController!, label: 'parent');
            }
          }
        }

        final dynamic savelsRaw = adata['savels'];
        if (savelsRaw is Map) {
          VegasDeviceProfileInstance.VegasSavels =
          Map<String, dynamic>.from(savelsRaw);
          VegasHunterLoggerService().VegasLogInfo(
              'savels stored in profile: ${VegasDeviceProfileInstance.VegasSavels}');
          _updateAppDataInLocalStorageFromProfile();
        }
      }
    } catch (e, st) {
      VegasHunterLoggerService()
          .VegasLogError('Error in _updateExtraDataFromServerPayload: $e\n$st');
    }
  }

  void _updateSafeAreaFromServerPayload(Map<dynamic, dynamic> root) {
    VegasHunterLoggerService()
        .VegasLogInfo('SAFEAREA RAW PAYLOAD: ${jsonEncode(root)}');

    bool? safearea;
    String? bgLightHex;
    String? bgDarkHex;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['safearea'] != null) {
        final dynamic raw = content['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (content['safearea_color'] != null &&
          content['safearea_color'].toString().trim().isNotEmpty) {
        bgLightHex = content['safearea_color'].toString().trim();
        bgDarkHex = bgLightHex;
      }
    }

    final dynamic adata = root['adata'];
    if (adata is Map) {
      if (safearea == null && adata['safearea'] != null) {
        final dynamic raw = adata['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (adata['bgsareaw'] != null &&
          adata['bgsareaw'].toString().trim().isNotEmpty) {
        bgLightHex = adata['bgsareaw'].toString().trim();
      }
      if (adata['bgsareab'] != null &&
          adata['bgsareab'].toString().trim().isNotEmpty) {
        bgDarkHex = adata['bgsareab'].toString().trim();
      }
    }

    if (safearea == null && root['safearea'] != null) {
      final dynamic raw = root['safearea'];
      if (raw is bool) {
        safearea = raw;
      } else if (raw is String) {
        final String v = raw.toLowerCase().trim();
        if (v == 'true' || v == '1' || v == 'yes') safearea = true;
        if (v == 'false' || v == '0' || v == 'no') safearea = false;
      } else if (raw is num) {
        safearea = raw != 0;
      }
    }

    VegasHunterLoggerService().VegasLogInfo(
        'SAFEAREA PARSED: enabled=$safearea, light=$bgLightHex, dark=$bgDarkHex');

    if (safearea == null) {
      return;
    }

    final Brightness platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? chosenHex;
    if (platformBrightness == Brightness.light) {
      chosenHex = bgLightHex ?? bgDarkHex;
    } else {
      chosenHex = bgDarkHex ?? bgLightHex;
    }

    final bool enabled = safearea;
    Color background =
    enabled ? const Color(0xFF1A1A22) : const Color(0xFF000000);

    if (enabled && chosenHex != null && chosenHex.isNotEmpty) {
      background = _parseHexColor(chosenHex);
    }

    setState(() {
      _safeAreaEnabled = enabled;
      _safeAreaBackgroundColor = background;
      VegasDeviceProfileInstance.VegasSafeAreaEnabled = enabled;
      VegasDeviceProfileInstance.VegasSafeAreaColor =
      enabled ? (chosenHex ?? '#1A1A22') : '';
    });

    () async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setBool('safearea_enabled', enabled);
        await prefs.setString(
          'safearea_color',
          VegasDeviceProfileInstance.VegasSafeAreaColor ?? '',
        );
        VegasHunterLoggerService().VegasLogInfo(
          'SafeArea saved to prefs: enabled=$enabled, color="${VegasDeviceProfileInstance.VegasSafeAreaColor}"',
        );
      } catch (e, st) {
        VegasHunterLoggerService().VegasLogError(
            'Error saving SafeArea to prefs: $e\n$st');
      }
    }();

    VegasHunterLoggerService().VegasLogInfo(
        'SAFEAREA STATE UPDATED: enabled=$_safeAreaEnabled, color=$_safeAreaBackgroundColor (brightness=$platformBrightness)');
  }

  bool _matchesButtonWhitelist(String url) {
    if (url.isEmpty) return false;
    if (_buttonWhitelist.isEmpty) return false;
    Uri? uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return false;
    }

    final String host = uri.host.toLowerCase();
    final String full = uri.toString();

    for (final String item in _buttonWhitelist) {
      final String trimmed = item.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        if (full.startsWith(trimmed)) return true;
      } else {
        final String domain = trimmed.toLowerCase();
        if (host == domain || host.endsWith('.$domain')) return true;
      }
    }

    return false;
  }

  Future<void> _updateBackButtonVisibility() async {
    final String current = _currentUrl ?? VegasCurrentUrl;
    final bool shouldShow = _matchesButtonWhitelist(current);

    if (_backButtonHiddenAfterTap) {
      _backButtonHiddenAfterTap = false;
    }

    if (shouldShow != _showBackButton) {
      if (mounted) {
        setState(() {
          _showBackButton = shouldShow;
        });
      } else {
        _showBackButton = shouldShow;
      }
    }
  }

  Future<void> _handleBackButtonPressed() async {
    if (mounted) {
      setState(() {
        _backButtonHiddenAfterTap = true;
        _showBackButton = false;
      });
    } else {
      _backButtonHiddenAfterTap = true;
      _showBackButton = false;
    }

    if (_isPopupVisible) {
      await _handlePopupBackPressed();
      return;
    }

    if (VegasWebViewController == null) return;
    try {
      if (await VegasWebViewController!.canGoBack()) {
        await VegasWebViewController!.goBack();
      } else {
        await VegasWebViewController!.loadUrl(
          urlRequest: URLRequest(url: WebUri(VegasHomeUrl)),
        );
      }
    } catch (e, st) {
      VegasHunterLoggerService()
          .VegasLogError('Error on back button pressed: $e\n$st');
    }
  }

  InAppWebViewSettings _mainWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: true,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  InAppWebViewSettings _popupWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
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

  Future<void> _safeEvaluateJavascript(
      InAppWebViewController? controller, {
        required String source,
        String debugName = 'js',
      }) async {
    if (controller == null) return;
    if (!mounted) return;

    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      print('WERLOG: safeEvaluateJavascript error [$debugName]: $e');
    }
  }

  Future<void> _installJsErrorLogger(InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installJsErrorLogger',
      source: r'''
        (function() {
          if (window.__ncupJsLoggerInstalled) return;
          window.__ncupJsLoggerInstalled = true;

          function serializeError(err) {
            try {
              if (!err) return null;
              var plain = {};
              Object.getOwnPropertyNames(err).forEach(function(key) {
                plain[key] = err[key];
              });
              return plain;
            } catch (_) {
              return { message: String(err) };
            }
          }

          window.onerror = function(message, source, lineno, colno, error) {
            try {
              var payload = {
                type: 'onerror',
                message: String(message || ''),
                source: String(source || ''),
                lineno: lineno || 0,
                colno: colno || 0,
                error: serializeError(error)
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger onerror inner fail', e);
            }
          };

          window.addEventListener('unhandledrejection', function(event) {
            try {
              var reason = event.reason;
              var payload = {
                type: 'unhandledrejection',
                reason: serializeError(reason) || { message: String(reason || '') }
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger unhandledrejection inner fail', e);
            }
          });
        })();
      ''',
    );
  }

  Future<void> _installPostMessageBridge(
      InAppWebViewController controller, {
        required String label,
      }) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installPostMessageBridge-$label',
      source: '''
        (function() {
          if (window.__ncupPostMessageBridgeInstalled_$label) return;
          window.__ncupPostMessageBridgeInstalled_$label = true;

          window.addEventListener('message', function(event) {
            try {
              var dataRaw = event.data;
              var dataString;
              try {
                dataString = JSON.stringify(dataRaw);
              } catch (e) {
                dataString = String(dataRaw);
              }

              var hasBridge = !!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler);

              var payload = {
                label: '$label',
                origin: String(event.origin || ''),
                data: dataString,
                href: String(window.location.href || '')
              };

              if (hasBridge) {
                window.flutter_inappwebview.callHandler('NcupPostMessage', payload);
              }

              try {
                var parsed = dataRaw;
                if (typeof parsed === 'string') {
                  parsed = JSON.parse(parsed);
                }
                if (parsed && parsed.type === 'newTab' && parsed.url) {
                  if (hasBridge) {
                    window.flutter_inappwebview.callHandler('NcupCheckoutAction', parsed);
                  }
                }
              } catch (parseErr) {}
            } catch (e) {}
          });
        })();
      ''',
    );
  }

  Future<void> _installCheckoutInterceptor(
      InAppWebViewController controller,
      ) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installCheckoutInterceptor',
      source: r'''
        (function() {
          if (window.__ncupCheckoutInterceptorInstalled) return;
          window.__ncupCheckoutInterceptorInstalled = true;

          function sendToFlutter(data) {
            try {
              if (!data || typeof data !== 'object') return;
              if (data.type === 'newTab' && data.url) {
                console.log('[NCUP checkout interceptor] newTab:', data.url);
                if (
                  window.flutter_inappwebview &&
                  window.flutter_inappwebview.callHandler
                ) {
                  window.flutter_inappwebview.callHandler(
                    'NcupCheckoutAction',
                    data
                  );
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] send error', e);
            }
          }

          function tryParseMaybeJson(value) {
            try {
              if (!value) return null;
              if (typeof value === 'object') {
                return value;
              }
              if (typeof value === 'string') {
                return JSON.parse(value);
              }
              return null;
            } catch (e) {
              return null;
            }
          }

          function tryHandlePayload(payload) {
            try {
              var data = tryParseMaybeJson(payload);
              if (!data) return;

              if (Array.isArray(data)) {
                data.forEach(function(item) {
                  if (item && item.type === 'newTab' && item.url) {
                    sendToFlutter(item);
                  }
                });
                return;
              }

              if (data.type === 'newTab' && data.url) {
                sendToFlutter(data);
                return;
              }

              if (data.savedata) {
                var saved = tryParseMaybeJson(data.savedata);
                if (saved && saved.type === 'newTab' && saved.url) {
                  sendToFlutter(saved);
                  return;
                }
              }

              if (data.data) {
                var nested = tryParseMaybeJson(data.data);
                if (nested && nested.type === 'newTab' && nested.url) {
                  sendToFlutter(nested);
                  return;
                }
              }

              if (data.content) {
                var content = tryParseMaybeJson(data.content);
                if (content && content.type === 'newTab' && content.url) {
                  sendToFlutter(content);
                  return;
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] handle error', e);
            }
          }

          var originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = function() {
              return originalFetch.apply(this, arguments).then(function(response) {
                try {
                  var cloned = response.clone();
                  cloned.text().then(function(text) {
                    tryHandlePayload(text);
                  }).catch(function() {});
                } catch (e) {}
                return response;
              });
            };
          }

          var OriginalXHR = window.XMLHttpRequest;
          if (OriginalXHR) {
            window.XMLHttpRequest = function() {
              var xhr = new OriginalXHR();
              var originalOpen = xhr.open;
              var originalSend = xhr.send;

              xhr.open = function() {
                return originalOpen.apply(xhr, arguments);
              };

              xhr.send = function() {
                xhr.addEventListener('load', function() {
                  try {
                    tryHandlePayload(xhr.responseText);
                  } catch (e) {}
                });
                return originalSend.apply(xhr, arguments);
              };

              return xhr;
            };
          }

          var originalOpen = window.open;
          window.open = function(url, target, features) {
            try {
              console.log('[NCUP window.open intercepted]', url, target, features);
            } catch (e) {}

            if (originalOpen) {
              return originalOpen.apply(window, arguments);
            }
            return null;
          };
        })();
      ''',
    );
  }

  Future<void> _installLocalStorageHook(
      InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installLocalStorageHook',
      source: r'''
        (function() {
          if (window.__ncupLocalStorageHookInstalled) return;
          window.__ncupLocalStorageHookInstalled = true;

          try {
            var originalSetItem = window.localStorage.setItem;
            window.localStorage.setItem = function(key, value) {
              try {
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                  window.flutter_inappwebview.callHandler('NcupLocalStorageSetItem', {
                    key: String(key),
                    value: String(value)
                  });
                }
              } catch (e) {
                console.log('Ncup localStorage hook error', e);
              }
              return originalSetItem.apply(this, arguments);
            };
          } catch (e) {
            console.log('Ncup localStorage hook init error', e);
          }
        })();
      ''',
    );
  }

  Future<void> _safeInstallAll(
      InAppWebViewController? controller, {
        required String label,
      }) async {
    if (controller == null) return;
    if (!mounted) return;
    if (!VegasDeviceProfileInstance.slotCasher) {
      print('WERLOG: safeInstallAll skipped ($label) because fpscashier=false');
      return;
    }

    try {
      await _installJsErrorLogger(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installPostMessageBridge(controller, label: label);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installCheckoutInterceptor(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installLocalStorageHook(controller);
    } catch (e) {
      print('WERLOG: safeInstallAll error label=$label error=$e');
    }
  }

  void _scheduleSafeInstall(
      InAppWebViewController controller, {
        required String label,
      }) {
    if (label == 'popup') {
      _popupInstallTimer?.cancel();
      _popupInstallTimer =
          Timer(const Duration(milliseconds: 450), () async {
            if (!mounted) return;
            await _safeInstallAll(controller, label: label);
          });
    } else {
      _parentInstallTimer?.cancel();
      _parentInstallTimer =
          Timer(const Duration(milliseconds: 250), () async {
            if (!mounted) return;
            await _safeInstallAll(controller, label: label);
          });
    }
  }

  Map<String, dynamic>? _tryDecodeMap(dynamic value) {
    try {
      if (value == null) return null;
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
      if (value is String) {
        final String trimmed = value.trim();
        if (trimmed.isEmpty) return null;
        final dynamic decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _openExternalForJsonNewTab(Uri uri) async {
    if (_isAboutBlankUri(uri)) return false;

    final String url = uri.toString();

    if (_handledNewTabUrls.contains(url)) {
      print('WERLOG: duplicate JSON newTab ignored url=$url');
      return true;
    }

    _handledNewTabUrls.add(url);

    if (_isOpeningExternalNewTab) {
      print('WERLOG: external newTab already opening, ignored url=$url');
      return false;
    }

    _isOpeningExternalNewTab = true;

    try {
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      print('WERLOG: JSON newTab external launched=$launched url=$url');
      return launched;
    } catch (e) {
      print('WERLOG: JSON newTab external error=$e url=$url');
      return false;
    } finally {
      Future<void>.delayed(const Duration(seconds: 2), () {
        _isOpeningExternalNewTab = false;
      });
    }
  }

  Future<bool> _handleCheckoutAction(dynamic rawPayload) async {
    try {
      Map<String, dynamic>? data = _tryDecodeMap(rawPayload);
      if (data == null) return false;

      if (data.containsKey('savedata')) {
        final Map<String, dynamic>? savedataMap =
        _tryDecodeMap(data['savedata']);
        if (savedataMap != null) {
          data = savedataMap;
        }
      }

      if (data.containsKey('data')) {
        final Map<String, dynamic>? dataMap = _tryDecodeMap(data['data']);
        if (dataMap != null &&
            dataMap['type']?.toString() == 'newTab' &&
            (dataMap['url']?.toString() ?? '').isNotEmpty) {
          data = dataMap;
        }
      }

      if (data.containsKey('content')) {
        final Map<String, dynamic>? contentMap =
        _tryDecodeMap(data['content']);
        if (contentMap != null &&
            contentMap['type']?.toString() == 'newTab' &&
            (contentMap['url']?.toString() ?? '').isNotEmpty) {
          data = contentMap;
        }
      }

      final String type = data['type']?.toString() ?? '';
      final String url = data['url']?.toString() ?? '';

      if (type == 'newTab' && url.isNotEmpty) {
        final Uri? uri = Uri.tryParse(url);
        if (uri == null || _isAboutBlankUri(uri)) {
          print('WERLOG: invalid JSON newTab uri=$url');
          return false;
        }

        // === OneLink: НЕ открываем во внешнем браузере ===
        if (VegasHunterIsRouletteUrl(uri)) {
          VegasHunterLoggerService().VegasLogInfo(
              'OneLink newTab detected, loading in WebView: $url');
          VegasNavigateToUri(url);
          return true;
        }

        print('WERLOG: handle JSON newTab url=$url');
        await _openExternalForJsonNewTab(uri);
        return true;
      }

      return false;
    } catch (e) {
      print('WERLOG: handleCheckoutAction error: $e');
      return false;
    }
  }

  Future<bool> _onCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction request,
      ) async {
    final Uri? vegasUri = request.request.url;
    final String urlString = vegasUri?.toString() ?? '';

    print(
      'WERLOG: MAIN onCreateWindow '
          'windowId=${request.windowId} '
          'url=$urlString '
          'isDialog=${request.isDialog} '
          'hasGesture=${request.hasGesture}',
    );

    if (vegasUri != null) {
      _currentUrl = vegasUri.toString();
      await _updateBackButtonVisibility();

      // === OneLink: загружаем внутри WebView, не открываем внешний браузер ===
      if (VegasHunterIsRouletteUrl(vegasUri)) {
        VegasHunterLoggerService().VegasLogInfo(
            'OneLink onCreateWindow: loading in main WebView: $vegasUri');
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(vegasUri.toString())),
        );
        return false;
      }

      if (_isGoogleUrl(vegasUri)) {}

      if (VegasHunterIsJackpotScheme(vegasUri) ||
          ((vegasUri.scheme == 'http' || vegasUri.scheme == 'https') &&
              VegasHunterIsJackpotDomain(vegasUri))) {
        await VegasHunterOpenJackpot(vegasUri);
        return false;
      }

      if (VegasIsBareEmail(vegasUri)) {
        final Uri vegasMailto = VegasToMailto(vegasUri);
        await VegasOpenMailExternal(vegasMailto);
        return false;
      }

      final String vegasScheme = vegasUri.scheme.toLowerCase();

      if (vegasScheme == 'mailto') {
        await VegasOpenMailExternal(vegasUri);
        return false;
      }

      if (vegasScheme == 'tel') {
        await launchUrl(vegasUri, mode: LaunchMode.externalApplication);
        return false;
      }

      final String host = vegasUri.host.toLowerCase();
      final bool vegasIsSocial = host.endsWith('facebook.com') ||
          host.endsWith('instagram.com') ||
          host.endsWith('twitter.com') ||
          host.endsWith('x.com');

      if (vegasIsSocial) {
        await VegasOpenExternal(vegasUri);
        return false;
      }

      if (VegasIsPlatformLink(vegasUri)) {
        final Uri vegasWebUri = VegasHttpizePlatformUri(vegasUri);
        await VegasOpenExternal(vegasWebUri);
        return false;
      }

    }

    if (!mounted) return false;

    setState(() {
      _popupCreateAction = request;
      _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
          ? urlString
          : null;
      _popupCurrentUrl = _popupUrl;
      _isPopupVisible = true;
      _popupCanGoBack = false;
    });

    return true;
  }

  Future<bool> _onPopupCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction createWindowAction,
      ) async {
    final Uri? uri = createWindowAction.request.url;
    final String urlString = uri?.toString() ?? '';

    print(
      'WERLOG: POPUP onCreateWindow '
          'windowId=${createWindowAction.windowId} '
          'url=$urlString',
    );

    // === OneLink в popup: загружаем в popup WebView ===
    if (uri != null && VegasHunterIsRouletteUrl(uri)) {
      VegasHunterLoggerService().VegasLogInfo(
          'OneLink popup onCreateWindow: loading in popup WebView: $uri');
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(uri.toString())),
      );
      return false;
    }

    if (!mounted) return false;

    if (createWindowAction.windowId != null) {
      setState(() {
        _popupCreateAction = createWindowAction;
        _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
            ? urlString
            : _popupUrl;
        _popupCurrentUrl = _popupUrl;
        _isPopupVisible = true;
      });
      return true;
    }

    if (urlString.isNotEmpty && !_isAboutBlankUrl(urlString)) {
      try {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(urlString)),
        );
      } catch (e) {
        print('WERLOG: popup inner window.open load error: $e url=$urlString');
      }
    }

    return false;
  }

  void _closePopup() {
    setState(() {
      _isPopupVisible = false;
      _popupUrl = null;
      _popupCurrentUrl = null;
      _popupCreateAction = null;
      _popupCanGoBack = false;
      VegasPopupWebViewController = null;
    });
  }

  Future<void> _closePopupAndNotifyParent({
    String reason = 'closed_by_user',
  }) async {
    try {
      await VegasWebViewController?.evaluateJavascript(
        source: '''
          try {
            window.dispatchEvent(new MessageEvent('message', {
              data: ${jsonEncode({
          'type': 'ncup_popup_closed',
          'reason': reason,
        })},
              origin: window.location.origin
            }));
          } catch(e) {
            console.log('ncup popup close notify failed', e);
          }
        ''',
      );
    } catch (e) {
      print('WERLOG: closePopup notify parent error: $e');
    }
    _closePopup();
  }

  Future<void> _refreshPopupCanGoBack() async {
    final InAppWebViewController? c = VegasPopupWebViewController;
    if (c == null) {
      if (_popupCanGoBack && mounted) {
        setState(() {
          _popupCanGoBack = false;
        });
      }
      return;
    }
    try {
      final bool can = await c.canGoBack();
      if (!mounted) return;
      if (can != _popupCanGoBack) {
        setState(() {
          _popupCanGoBack = can;
        });
      }
    } catch (e) {
      print('WERLOG: _refreshPopupCanGoBack error: $e');
    }
  }

  Future<void> _handlePopupBackPressed() async {
    final InAppWebViewController? c = VegasPopupWebViewController;
    if (c == null) {
      _closePopup();
      return;
    }
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          _refreshPopupCanGoBack();
        });
      } else {
        await _closePopupAndNotifyParent(reason: 'popup_back_no_history');
      }
    } catch (e) {
      print('WERLOG: _handlePopupBackPressed error: $e');
      _closePopup();
    }
  }

  bool _isCurrentPopupInWhitelist() {
    if (!_isPopupVisible) return false;
    final String popupUrlForCheck = _popupCurrentUrl ?? _popupUrl ?? '';
    return _matchesButtonWhitelist(popupUrlForCheck);
  }

  Widget _buildPopupWebView() {
    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool showBackArrow = !popupInWhitelist && _popupCanGoBack;
    final bool showCloseButton = !popupInWhitelist && !_popupCanGoBack;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            if (!popupInWhitelist) ...[
              SafeArea(
                bottom: false,
                child: Container(
                  color: Colors.black,
                  child: Row(
                    children: [
                      if (showBackArrow)
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white),
                          onPressed: _handlePopupBackPressed,
                        )
                      else if (showCloseButton)
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () {
                            _closePopupAndNotifyParent(reason: 'close_button');
                          },
                        ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
            ],
            Expanded(
              child: InAppWebView(
                windowId: _popupCreateAction?.windowId,
                initialUrlRequest:
                (_popupCreateAction?.windowId == null) && _popupUrl != null
                    ? URLRequest(url: WebUri(_popupUrl!))
                    : null,
                initialSettings: _popupWebViewSettings(),
                onWebViewCreated:
                    (InAppWebViewController popupController) async {
                  VegasPopupWebViewController = popupController;

                  print(
                    'WERLOG: popup created '
                        'windowId=${_popupCreateAction?.windowId} '
                        'initialUrl=${_popupUrl ?? _popupCreateAction?.request.url}',
                  );

                  final String popupInitUrl =
                      _popupUrl ?? _popupCreateAction?.request.url?.toString() ?? '';
                  if (popupInitUrl.isNotEmpty) {
                    final Uri? popupUri = Uri.tryParse(popupInitUrl);
                    if (popupUri != null && _isGoogleUrl(popupUri)) {
                      await _applyGoogleUserAgentForPopup();
                    }
                  }

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupLocalStorageSetItem',
                    callback: (List<dynamic> args) async {
                      try {
                        if (args.isEmpty) return null;
                        final dynamic raw = args.first;
                        if (raw is Map) {
                          final String key = raw['key']?.toString() ?? '';
                          final String value = raw['value']?.toString() ?? '';
                          if (key.isNotEmpty) {
                            final SharedPreferences prefs =
                            await SharedPreferences.getInstance();
                            await prefs.setString(key, value);
                            VegasHunterLoggerService().VegasLogInfo(
                                'NcupLocalStorageSetItem (popup): saved key="$key" len=${value.length}');
                          }
                        }
                      } catch (e, st) {
                        VegasHunterLoggerService().VegasLogError(
                            'NcupLocalStorageSetItem popup handler error: $e\n$st');
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupCheckoutAction',
                    callback: (List<dynamic> args) async {
                      print('WERLOG: POPUP NcupCheckoutAction args=$args');
                      if (args.isNotEmpty) {
                        await _handleCheckoutAction(args.first);
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupPostMessage',
                    callback: (List<dynamic> args) async {
                      try {
                        if (args.isEmpty) return null;
                        final dynamic first = args.first;
                        final dynamic dataToHandle = (first is Map && first['data'] != null)
                            ? first['data']
                            : first;
                        await _handleCheckoutAction(dataToHandle);
                      } catch (e) {
                        print('WERLOG: POPUP NcupPostMessage handler error: $e');
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupJSLogger',
                    callback: (List<dynamic> args) {
                      print('WERLOG: POPUP JS error payload: $args');
                      return null;
                    },
                  );
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStart: (controller, uri) async {
                  print('WERLOG: popup onLoadStart url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (_isGoogleUrl(uri)) {
                      await _applyGoogleUserAgentForPopup();
                    }

                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onLoadStop: (controller, uri) async {
                  print('WERLOG: popup onLoadStop url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                      });
                    }
                  }
                  if (!_isAboutBlankUri(uri)) {
                    _scheduleSafeInstall(controller, label: 'popup');
                  }
                  _refreshPopupCanGoBack();
                },
                onUpdateVisitedHistory: (controller, url, isReload) async {
                  if (url != null && !_isAboutBlankUri(url)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = url.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onCreateWindow: _onPopupCreateWindowHandler,
                shouldOverrideUrlLoading: (
                    InAppWebViewController controller,
                    NavigationAction navigationAction,
                    ) async {
                  final Uri? uri = navigationAction.request.url;
                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isAboutBlankUri(uri)) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  // === OneLink: разрешаем навигацию внутри popup ===
                  if (VegasHunterIsRouletteUrl(uri)) {
                    VegasHunterLoggerService().VegasLogInfo(
                        'OneLink popup shouldOverride: ALLOW in popup: $uri');
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isGoogleUrl(uri)) {
                    await _applyGoogleUserAgentForPopup();
                    return NavigationActionPolicy.ALLOW;
                  }

                  final String scheme = uri.scheme.toLowerCase();

                  if (VegasIsBareEmail(uri)) {
                    final Uri mailto = VegasToMailto(uri);
                    await VegasOpenMailExternal(mailto);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'mailto') {
                    await VegasOpenMailExternal(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'tel') {
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (VegasHunterIsJackpotScheme(uri) ||
                      ((scheme == 'http' || scheme == 'https') &&
                          VegasHunterIsJackpotDomain(uri))) {
                    await VegasHunterOpenJackpot(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme != 'http' && scheme != 'https') {
                    print(
                      'WERLOG: popup non-http/https scheme=$scheme url=$uri, trying external app',
                    );
                    await VegasHunterTryOpenUnknownSchemeExternally(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (controller) {
                  print('WERLOG: popup onCloseWindow');
                  _closePopup();
                },
                onLoadError: (controller, uri, code, message) async {
                  print(
                    'WERLOG: popup onLoadError url=$uri code=$code msg=$message',
                  );
                },
                onReceivedError: (controller, request, error) async {
                  print(
                    'WERLOG: popup onReceivedError '
                        'url=${request.url} '
                        'type=${error.type} '
                        'desc=${error.description}',
                  );
                },
                onReceivedHttpError:
                    (controller, request, errorResponse) async {
                  print(
                    'WERLOG: popup onReceivedHttpError '
                        'url=${request.url} '
                        'status=${errorResponse.statusCode} '
                        'reason=${errorResponse.reasonPhrase}',
                  );
                },
                onConsoleMessage: (controller, consoleMessage) {
                  print(
                    'WERLOG: popup console: '
                        '${consoleMessage.messageLevel} ${consoleMessage.message}',
                  );
                },
                onDownloadStartRequest: (controller, req) async {
                  print(
                      'WERLOG: popup download for url=${req.url}, opening external');
                  await VegasOpenExternal(req.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    VegasBindNotificationTap();

    final Color bgColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget webView = Stack(
      children: <Widget>[
        if (VegasCoverVisible)
          const Center(child: VLLoaderScreen())
        else
          Container(
            color: bgColor,
            child: Stack(
              children: <Widget>[
                InAppWebView(
                  key: ValueKey<int>(VegasWebViewKeyCounter),
                  initialSettings: _mainWebViewSettings(),
                  initialUrlRequest: URLRequest(
                    url: WebUri(VegasHomeUrl),
                  ),
                  onWebViewCreated:
                      (InAppWebViewController controller) async {
                    VegasWebViewController = controller;
                    _currentUrl = VegasHomeUrl;

                    VegasDealerInstance ??= VegasHunterDealerViewModel(
                      VegasDeviceProfileInstance: VegasDeviceProfileInstance,
                      VegasSpyInstance: VegasSpyInstance,
                    );

                    VegasCourier ??= VegasHunterCourierService(
                      VegasDealer: VegasDealerInstance!,
                      VegasGetWebViewController: () => VegasWebViewController,
                    );

                    try {
                      final ua = await controller.evaluateJavascript(
                        source: "navigator.userAgent",
                      );
                      if (ua is String && ua.trim().isNotEmpty) {
                        _baseUserAgent = ua.trim();
                        _currentUserAgent = _baseUserAgent!;
                        VegasDeviceProfileInstance.VegasBaseUserAgent =
                            _baseUserAgent;
                        VegasHunterLoggerService().VegasLogInfo(
                            'Initial WebView User-Agent: $_baseUserAgent');
                        print(
                            '[UA] INITIAL WEBVIEW USER AGENT: $_baseUserAgent');
                      }
                    } catch (e) {
                      VegasHunterLoggerService().VegasLogWarn(
                          'Failed to read navigator.userAgent on create: $e');
                    }

                    await _applyNormalUserAgentIfNeeded();

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupLocalStorageSetItem',
                      callback: (List<dynamic> args) async {
                        try {
                          if (args.isEmpty) return null;
                          final dynamic raw = args.first;
                          if (raw is Map) {
                            final String key =
                                raw['key']?.toString() ?? '';
                            final String value =
                                raw['value']?.toString() ?? '';
                            if (key.isNotEmpty) {
                              final SharedPreferences prefs =
                              await SharedPreferences.getInstance();
                              await prefs.setString(key, value);
                              VegasHunterLoggerService().VegasLogInfo(
                                  'NcupLocalStorageSetItem (main): saved key="$key" len=${value.length}');
                            }
                          }
                        } catch (e, st) {
                          VegasHunterLoggerService().VegasLogError(
                              'NcupLocalStorageSetItem main handler error: $e\n$st');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'onServerResponse',
                      callback: (List<dynamic> args) async {
                        if (args.isEmpty) return null;

                        print("Get Data server $args");

                        try {
                          dynamic first = args[0];

                          if (first is List && first.isNotEmpty) {
                            first = first.first;
                          }

                          final bool handled =
                          await _handleCheckoutAction(first);
                          if (handled) {}

                          if (first is Map) {
                            final Map<dynamic, dynamic> root = first;

                            if (root['savedata'] != null) {
                              VegasHandleServerSavedata(
                                  root['savedata'].toString());
                              await _handleCheckoutAction(root['savedata']);
                            }

                            _updateExtraDataFromServerPayload(root);
                            _updateSafeAreaFromServerPayload(root);
                            await _updateUserAgentFromServerPayload(root);

                            await _applyNormalUserAgentIfNeeded();

                            try {
                              if (!_loadedJsExecutedOnce) {
                                final dynamic adataRaw = root['adata'];
                                if (adataRaw is Map) {
                                  final Map adata = adataRaw;
                                  final dynamic loadedJsRaw =
                                  adata['loadedjs'];
                                  if (loadedJsRaw != null) {
                                    final String loadedJs =
                                    loadedJsRaw.toString().trim();
                                    if (loadedJs.isNotEmpty) {
                                      _pendingLoadedJs = loadedJs;
                                      VegasHunterLoggerService().VegasLogInfo(
                                        'loadedjs received, will execute ONCE after 6 seconds',
                                      );

                                      Future<void>.delayed(
                                        const Duration(seconds: 6),
                                            () async {
                                          if (!mounted) return;
                                          if (_loadedJsExecutedOnce) {
                                            VegasHunterLoggerService()
                                                .VegasLogInfo(
                                                'Skipping loadedjs: already executed once');
                                            return;
                                          }
                                          if (VegasWebViewController ==
                                              null) {
                                            VegasHunterLoggerService()
                                                .VegasLogWarn(
                                                'Skipping loadedjs execution: controller is null');
                                            return;
                                          }
                                          final String? jsToRun =
                                              _pendingLoadedJs;
                                          if (jsToRun == null ||
                                              jsToRun.isEmpty) {
                                            return;
                                          }
                                          VegasHunterLoggerService().VegasLogInfo(
                                              'Executing loadedjs from server payload (ONCE, delayed 6s)');
                                          try {
                                            await VegasWebViewController
                                                ?.evaluateJavascript(
                                              source: jsToRun,
                                            );
                                            _loadedJsExecutedOnce = true;
                                          } catch (e, st) {
                                            VegasHunterLoggerService().VegasLogError(
                                                'Error executing delayed loadedjs: $e\n$st');
                                          }
                                        },
                                      );
                                    }
                                  }
                                }
                              } else {
                                VegasHunterLoggerService().VegasLogInfo(
                                    'loadedjs ignored: already executed once earlier');
                              }
                            } catch (e, st) {
                              VegasHunterLoggerService().VegasLogError(
                                  'Error scheduling loadedjs: $e\n$st');
                            }
                          }
                        } catch (e, st) {
                          print('onServerResponse error: $e\n$st');
                        }

                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupCheckoutAction',
                      callback: (List<dynamic> args) async {
                        try {
                          print('WERLOG: MAIN NcupCheckoutAction args=$args');
                          if (args.isNotEmpty) {
                            await _handleCheckoutAction(args.first);
                          }
                        } catch (e) {
                          print(
                              'WERLOG: MAIN NcupCheckoutAction error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupJSLogger',
                      callback: (List<dynamic> args) {
                        try {
                          final dynamic payload =
                          args.isNotEmpty ? args.first : null;
                          print('WERLOG: MAIN JS error payload: $payload');
                        } catch (e) {
                          print('WERLOG: NcupJSLogger handler error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupPostMessage',
                      callback: (List<dynamic> args) async {
                        try {
                          if (args.isEmpty) return null;
                          final dynamic first = args.first;
                          final dynamic dataToHandle = (first is Map && first['data'] != null)
                              ? first['data']
                              : first;
                          await _handleCheckoutAction(dataToHandle);
                        } catch (e) {
                          print('WERLOG: MAIN NcupPostMessage handler error: $e');
                        }
                        return null;
                      },
                    );
                  },
                  onPermissionRequest: (controller, request) async {
                    return PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.GRANT,
                    );
                  },
                  onLoadStart:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      VegasStartLoadTimestamp =
                          DateTime.now().millisecondsSinceEpoch;
                    });

                    final Uri? vegasViewUri = uri;
                    if (vegasViewUri != null) {
                      _currentUrl = vegasViewUri.toString();

                      await _switchUserAgentForUrl(vegasViewUri);

                      await _updateBackButtonVisibility();

                      if (VegasIsBareEmail(vegasViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        final Uri vegasMailto = VegasToMailto(vegasViewUri);
                        await VegasOpenMailExternal(vegasMailto);
                        return;
                      }

                      final String vegasScheme =
                      vegasViewUri.scheme.toLowerCase();

                      if (vegasScheme == 'mailto') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await VegasOpenMailExternal(vegasViewUri);
                        return;
                      }

                      if (VegasHunterIsJackpotScheme(vegasViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await VegasHunterOpenJackpot(vegasViewUri);
                        return;
                      }

                      if (vegasScheme != 'http' && vegasScheme != 'https') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await VegasHunterTryOpenUnknownSchemeExternally(vegasViewUri);
                      }
                    }
                  },
                  onLoadError: (
                      InAppWebViewController controller,
                      Uri? uri,
                      int code,
                      String message,
                      ) async {
                    if (VegasHunterIsCancelledLoadError(description: message)) {
                      print('WERLOG: ignoring cancelled load (code=$code, url=$uri)');
                      return;
                    }

                    final int vegasNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String vegasEvent =
                        'InAppWebViewError(code=$code, message=$message)';

                    await VegasHunterPostStat(
                      event: vegasEvent,
                      timeStart: vegasNow,
                      timeFinish: vegasNow,
                      url: uri?.toString() ?? '',
                      appSid: VegasSpyInstance.VegasAppsFlyerUid,
                      firstPageLoadTs: VegasFirstPageTimestamp,
                    );
                  },
                  onReceivedError: (
                      InAppWebViewController controller,
                      WebResourceRequest request,
                      WebResourceError error,
                      ) async {
                    final String vegasDescription =
                    (error.description ?? '').toString();

                    if (VegasHunterIsCancelledLoadError(
                        description: vegasDescription, type: error.type)) {
                      print(
                          'WERLOG: ignoring cancelled load (type=${error.type}, url=${request.url})');
                      return;
                    }

                    final int vegasNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String vegasEvent =
                        'WebResourceError(code=$error, message=$vegasDescription)';

                    await VegasHunterPostStat(
                      event: vegasEvent,
                      timeStart: vegasNow,
                      timeFinish: vegasNow,
                      url: request.url?.toString() ?? '',
                      appSid: VegasSpyInstance.VegasAppsFlyerUid,
                      firstPageLoadTs: VegasFirstPageTimestamp,
                    );
                  },
                  onLoadStop:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      VegasCurrentUrl = uri.toString();
                      _currentUrl = VegasCurrentUrl;
                    });

                    if (uri != null) {
                      await _switchUserAgentForUrl(uri);
                    }

                    if (!_isAboutBlankUri(uri)) {
                      _scheduleSafeInstall(controller, label: 'parent');
                    }

                    await vegasDebugPrintCurrentUserAgent();

                    await _sendAllDataToPageTwice();
                    await _updateBackButtonVisibility();

                    Future<void>.delayed(
                      const Duration(seconds: 20),
                          () {
                        VegasSendLoadedOnce(
                          url: VegasCurrentUrl.toString(),
                          timestart: VegasStartLoadTimestamp,
                        );
                      },
                    );
                  },
                  onUpdateVisitedHistory:
                      (controller, url, isReload) async {
                    if (url != null && !_isAboutBlankUri(url)) {
                      _currentUrl = url.toString();
                      await _updateBackButtonVisibility();
                      await _switchUserAgentForUrl(url);
                    }
                  },
                  shouldOverrideUrlLoading:
                      (InAppWebViewController controller,
                      NavigationAction action) async {
                    final Uri? vegasUri = action.request.url;
                    if (vegasUri == null) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    _currentUrl = vegasUri.toString();
                    await _updateBackButtonVisibility();

                    if (_isAboutBlankUri(vegasUri)) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    // === OneLink: ВСЕГДА разрешаем навигацию внутри WebView ===
                    if (VegasHunterIsRouletteUrl(vegasUri)) {
                      VegasHunterLoggerService().VegasLogInfo(
                          'OneLink shouldOverride: ALLOW in WebView: $vegasUri');
                      return NavigationActionPolicy.ALLOW;
                    }

                    if (_isGoogleUrl(vegasUri)) {
                      _isCurrentlyOnGoogle = true;
                      await _applyGoogleUserAgent();
                      return NavigationActionPolicy.ALLOW;
                    } else {
                      if (_isCurrentlyOnGoogle) {
                        _isCurrentlyOnGoogle = false;
                      }
                      await _applyNormalUserAgentIfNeeded();
                    }

                    if (VegasIsBareEmail(vegasUri)) {
                      final Uri vegasMailto = VegasToMailto(vegasUri);
                      await VegasOpenMailExternal(vegasMailto);
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String vegasScheme = vegasUri.scheme.toLowerCase();

                    if (vegasScheme == 'mailto') {
                      await VegasOpenMailExternal(vegasUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (VegasHunterIsJackpotScheme(vegasUri)) {
                      await VegasHunterOpenJackpot(vegasUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if ((vegasScheme == 'http' || vegasScheme == 'https') &&
                        VegasHunterIsJackpotDomain(vegasUri)) {
                      await VegasHunterOpenJackpot(vegasUri);

                      if (_isAdobeRedirect(vegasUri)) {
                        if (context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  VegasHunterAdobeRedirectScreen(uri: vegasUri),
                            ),
                          );
                        }
                        return NavigationActionPolicy.CANCEL;
                      }
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (vegasScheme == 'tel') {
                      await launchUrl(
                        vegasUri,
                        mode: LaunchMode.externalApplication,
                      );
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String host = vegasUri.host.toLowerCase();
                    final bool vegasIsSocial =
                        host.endsWith('facebook.com') ||
                            host.endsWith('instagram.com') ||
                            host.endsWith('twitter.com') ||
                            host.endsWith('x.com');

                    if (vegasIsSocial) {
                      await VegasOpenExternal(vegasUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (VegasIsPlatformLink(vegasUri)) {
                      final Uri vegasWebUri =
                      VegasHttpizePlatformUri(vegasUri);
                      await VegasOpenExternal(vegasWebUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (vegasScheme != 'http' && vegasScheme != 'https') {
                      await VegasHunterTryOpenUnknownSchemeExternally(vegasUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    return NavigationActionPolicy.ALLOW;
                  },
                  onCreateWindow: _onCreateWindowHandler,
                  onCloseWindow: (controller) {
                    print('WERLOG: MAIN onCloseWindow');
                  },
                  onDownloadStartRequest: (
                      InAppWebViewController controller,
                      DownloadStartRequest req,
                      ) async {
                    await VegasOpenExternal(req.url);
                  },
                  onConsoleMessage: (controller, consoleMessage) {
                    print(
                      'WERLOG: MAIN console: '
                          '${consoleMessage.messageLevel} ${consoleMessage.message}',
                    );
                  },
                ),
                Visibility(
                  visible: !VegasVeilVisible,
                  child: const Center(child: VLLoaderScreen()),
                ),
                if (_isPopupVisible &&
                    (_popupUrl != null || _popupCreateAction != null))
                  _buildPopupWebView(),
              ],
            ),
          ),
      ],
    );

    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool whitelistMatch =
        (!_isPopupVisible && _showBackButton) || popupInWhitelist;

    final bool shouldShowTopBackBar =
        whitelistMatch && !_backButtonHiddenAfterTap;

    final Color topBarColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget topBackBar = shouldShowTopBackBar
        ? Container(
      color: topBarColor,
      padding: const EdgeInsets.only(left: 4, right: 4),
      height: 48,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _handleBackButtonPressed,
          ),
        ],
      ),
    )
        : const SizedBox.shrink();

    final Widget fullScreen = Column(
      children: [
        topBackBar,
        Expanded(child: webView),
      ],
    );

    final Widget body = _safeAreaEnabled
        ? SafeArea(
      child: fullScreen,
    )
        : fullScreen;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: bgColor,
        body: SizedBox.expand(
          child: ColoredBox(
            color: bgColor,
            child: body,
          ),
        ),
      ),
    );
  }

  bool _isAdobeRedirect(Uri uri) {
    final String host = uri.host.toLowerCase();
    return host == 'c00.adobe.com';
  }
}

// ---------------------- Экран для c00.adobe.com ----------------------

class VegasHunterAdobeRedirectScreen extends StatelessWidget {
  final Uri uri;

  const VegasHunterAdobeRedirectScreen({super.key, required this.uri});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF111111),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Go to the App Store and download the app.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                ),
              ),
              SizedBox(height: 24),
              SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// main()
// ============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(VegasHunterFcmBackgroundHandler);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  tz_data.initializeTimeZones();

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: VegasHunterLobby(),
    ),
  );
}