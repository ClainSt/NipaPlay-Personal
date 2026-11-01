import 'package:flutter/foundation.dart';
import 'package:nipaplay/constants/settings_keys.dart';
import 'package:nipaplay/utils/settings_storage.dart';

enum LibraryScrapeMode { original, tmdbId }

class LabsSettingsProvider extends ChangeNotifier {
  LabsSettingsProvider() {
    ready = _loadSettings();
  }

  /// Completes after the persisted lab switches have been restored.
  ///
  /// Routes that make a one-shot decision from these values must await this
  /// future; otherwise an app launch can observe the in-memory defaults before
  /// SharedPreferences has finished loading.
  late final Future<void> ready;

  bool _enableImmersiveAnimeDetail = false;
  bool _enableCloudAnimeDetailSections = false;
  LibraryScrapeMode _localLibraryScrapeMode = LibraryScrapeMode.original;
  LibraryScrapeMode _webDavLibraryScrapeMode = LibraryScrapeMode.original;
  bool _isLoaded = false;

  bool get enableImmersiveAnimeDetail => _enableImmersiveAnimeDetail;
  bool get enableCloudAnimeDetailSections => _enableCloudAnimeDetailSections;
  LibraryScrapeMode get localLibraryScrapeMode => _localLibraryScrapeMode;
  LibraryScrapeMode get webDavLibraryScrapeMode => _webDavLibraryScrapeMode;
  bool get isLoaded => _isLoaded;

  Future<void> _loadSettings() async {
    _enableImmersiveAnimeDetail = await SettingsStorage.loadBool(
      SettingsKeys.labsEnableImmersiveAnimeDetail,
      defaultValue: false,
    );
    _enableCloudAnimeDetailSections = await SettingsStorage.loadBool(
      SettingsKeys.labsEnableCloudAnimeDetailSections,
      defaultValue: false,
    );
    _localLibraryScrapeMode = _readScrapeMode(
      await SettingsStorage.loadString(
        SettingsKeys.labsLocalLibraryScrapeMode,
        defaultValue: 'original',
      ),
    );
    _webDavLibraryScrapeMode = _readScrapeMode(
      await SettingsStorage.loadString(
        SettingsKeys.labsWebDavLibraryScrapeMode,
        defaultValue: 'original',
      ),
    );
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setEnableImmersiveAnimeDetail(bool enabled) async {
    await ready;
    if (_enableImmersiveAnimeDetail == enabled) return;
    _enableImmersiveAnimeDetail = enabled;
    notifyListeners();
    await SettingsStorage.saveBool(
      SettingsKeys.labsEnableImmersiveAnimeDetail,
      enabled,
    );
  }

  Future<void> setEnableCloudAnimeDetailSections(bool enabled) async {
    await ready;
    if (_enableCloudAnimeDetailSections == enabled) return;
    _enableCloudAnimeDetailSections = enabled;
    notifyListeners();
    await SettingsStorage.saveBool(
      SettingsKeys.labsEnableCloudAnimeDetailSections,
      enabled,
    );
  }

  Future<void> setLocalLibraryScrapeMode(LibraryScrapeMode mode) async {
    await ready;
    if (_localLibraryScrapeMode == mode) return;
    _localLibraryScrapeMode = mode;
    notifyListeners();
    await SettingsStorage.saveString(
      SettingsKeys.labsLocalLibraryScrapeMode,
      mode.name,
    );
  }

  Future<void> setWebDavLibraryScrapeMode(LibraryScrapeMode mode) async {
    await ready;
    if (_webDavLibraryScrapeMode == mode) return;
    _webDavLibraryScrapeMode = mode;
    notifyListeners();
    await SettingsStorage.saveString(
      SettingsKeys.labsWebDavLibraryScrapeMode,
      mode.name,
    );
  }

  static LibraryScrapeMode _readScrapeMode(String? value) =>
      value == LibraryScrapeMode.tmdbId.name
          ? LibraryScrapeMode.tmdbId
          : LibraryScrapeMode.original;
}
