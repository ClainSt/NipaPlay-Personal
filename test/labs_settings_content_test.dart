import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/l10n/app_localizations.dart';
import 'package:nipaplay/providers/appearance_settings_provider.dart';
import 'package:nipaplay/providers/labs_settings_provider.dart';
import 'package:nipaplay/settings/pages/labs_settings_content.dart';
import 'package:nipaplay/themes/nipaplay/widgets/fluent_settings_switch.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    messenger.setMockMethodCallHandler(secureStorageChannel, (_) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
  });

  testWidgets(
      'labs page exposes independent scrape switches without a new UI switch',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = LabsSettingsProvider();
    final appearance = AppearanceSettingsProvider();
    addTearDown(settings.dispose);
    addTearDown(appearance.dispose);
    await settings.ready;
    await appearance.ready;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LabsSettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AppearanceSettingsProvider>.value(
            value: appearance,
          ),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: LabsSettingsContent(onOpenWebDavQuickSettings: _noop),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本地媒体库刮削模式'), findsOneWidget);
    expect(find.text('WebDAV 媒体库刮削模式'), findsOneWidget);
    expect(find.text('全新UI'), findsNothing);

    var switches = tester
        .widgetList<FluentSettingsSwitch>(find.byType(FluentSettingsSwitch))
        .toList();
    expect(switches.length, greaterThanOrEqualTo(2));
    expect(switches[0].value, isFalse);
    expect(switches[1].value, isFalse);

    switches[0].onChanged!(true);
    await tester.pumpAndSettle();
    expect(settings.localLibraryScrapeMode, LibraryScrapeMode.tmdbId);
    expect(settings.webDavLibraryScrapeMode, LibraryScrapeMode.original);
    expect(settings.enableCloudAnimeDetailSections, isFalse);

    switches = tester
        .widgetList<FluentSettingsSwitch>(find.byType(FluentSettingsSwitch))
        .toList();
    switches[1].onChanged!(true);
    await tester.pumpAndSettle();
    expect(settings.localLibraryScrapeMode, LibraryScrapeMode.tmdbId);
    expect(settings.webDavLibraryScrapeMode, LibraryScrapeMode.tmdbId);
    expect(settings.enableCloudAnimeDetailSections, isFalse);
  });
}

void _noop() {}
