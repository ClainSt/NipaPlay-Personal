import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/material.dart';
import 'package:kmbal_ionicons/kmbal_ionicons.dart';
import 'package:nipaplay/l10n/l10n.dart';
import 'package:nipaplay/providers/labs_settings_provider.dart';
import 'package:nipaplay/settings/adaptive_settings_widgets.dart';
import 'package:nipaplay/themes/nipaplay/widgets/blur_dropdown.dart';
import 'package:nipaplay/utils/globals.dart' as globals;
import 'package:provider/provider.dart';

class LabsSettingsContent extends StatelessWidget {
  const LabsSettingsContent({
    super.key,
    required this.onOpenWebDavQuickSettings,
  });

  final VoidCallback onOpenWebDavQuickSettings;

  @override
  Widget build(BuildContext context) {
    return Consumer<LabsSettingsProvider>(
      builder: (context, labsSettings, child) {
        return AdaptiveSettingsPage(
          children: [
            AdaptiveSettingsSection(
              dividerIndent: 56,
              children: [
                AdaptiveSettingsTile.dropdown(
                  title: '本地媒体库刮削模式',
                  subtitle: labsSettings.localLibraryScrapeMode ==
                          LibraryScrapeMode.tmdbId
                      ? '从文件夹 TMDB ID 直接识别；不读取视频内容'
                      : '使用 NipaPlay 原版扫描和匹配流程',
                  icon: Icons.folder_outlined,
                  phoneIcon: cupertino.CupertinoIcons.folder,
                  items: <DropdownMenuItemData<LibraryScrapeMode>>[
                    DropdownMenuItemData(
                      value: LibraryScrapeMode.original,
                      title: '原版模式',
                    ),
                    DropdownMenuItemData(
                      value: LibraryScrapeMode.tmdbId,
                      title: 'TMDB-ID 模式',
                    ),
                  ],
                  onChanged: labsSettings.setLocalLibraryScrapeMode,
                ),
                AdaptiveSettingsTile.dropdown(
                  title: 'WebDAV 媒体库刮削模式',
                  subtitle: labsSettings.webDavLibraryScrapeMode ==
                          LibraryScrapeMode.tmdbId
                      ? '从文件夹 TMDB ID 直接识别；扫描只请求目录元数据'
                      : '使用 NipaPlay 原版 WebDAV 刮削流程',
                  icon: Ionicons.cloud_outline,
                  phoneIcon: cupertino.CupertinoIcons.cloud,
                  items: <DropdownMenuItemData<LibraryScrapeMode>>[
                    DropdownMenuItemData(
                      value: LibraryScrapeMode.original,
                      title: '原版模式',
                    ),
                    DropdownMenuItemData(
                      value: LibraryScrapeMode.tmdbId,
                      title: 'TMDB-ID 模式',
                    ),
                  ],
                  onChanged: labsSettings.setWebDavLibraryScrapeMode,
                ),
                AdaptiveSettingsTile.toggle(
                  title: '动画详情显示媒体分类',
                  subtitle: '开启后在动画详情页增加正片、特典、CDs 和 Scans 分类；关闭时保留原版详情页布局',
                  icon: Ionicons.albums_outline,
                  phoneIcon: cupertino.CupertinoIcons.rectangle_stack,
                  value: labsSettings.enableCloudAnimeDetailSections,
                  onChanged: labsSettings.setEnableCloudAnimeDetailSections,
                ),
                if (!globals.isTelevision)
                  AdaptiveSettingsTile.toggle(
                    title: _text(
                      context,
                      '新版番剧卡片页面',
                      '新版番劇卡片頁面',
                      'New Anime Detail Page',
                    ),
                    subtitle: _text(
                      context,
                      '开启后，桌面、平板和手机均使用新版全屏番剧详情页',
                      '開啟後，桌面、平板和手機均使用新版全螢幕番劇詳情頁',
                      'Use the new full-screen anime detail page on desktop, tablet, and phone.',
                    ),
                    icon: Ionicons.albums_outline,
                    phoneIcon: cupertino.CupertinoIcons.rectangle_stack,
                    value: labsSettings.enableImmersiveAnimeDetail,
                    onChanged: labsSettings.setEnableImmersiveAnimeDetail,
                  ),
                AdaptiveSettingsTile.button(
                  title: _text(
                    context,
                    'WebDAV 快捷设置',
                    'WebDAV 快捷設定',
                    'WebDAV Quick Settings',
                  ),
                  subtitle: _text(
                    context,
                    '配置底部 WebDAV 快捷 Tab，快速访问 WebDAV 服务器',
                    '配置底部 WebDAV 快捷 Tab，快速訪問 WebDAV 伺服器',
                    'Configure the bottom WebDAV shortcut tab.',
                  ),
                  icon: Ionicons.cloud_outline,
                  phoneIcon: cupertino.CupertinoIcons.cloud,
                  trailingIcon: Ionicons.chevron_forward,
                  onTap: onOpenWebDavQuickSettings,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  String _text(
    BuildContext context,
    String simplified,
    String traditional,
    String english,
  ) {
    final localeName = context.l10n.localeName;
    if (localeName.startsWith('zh_Hant')) {
      return traditional;
    }
    if (localeName.startsWith('en')) {
      return english;
    }
    return simplified;
  }
}
