import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/material.dart';
import 'package:kmbal_ionicons/kmbal_ionicons.dart';
import 'package:nipaplay/l10n/l10n.dart';
import 'package:nipaplay/providers/labs_settings_provider.dart';
import 'package:nipaplay/settings/adaptive_settings_widgets.dart';
import 'package:nipaplay/widgets/in_view_dialog.dart';
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
                AdaptiveSettingsTile.toggle(
                  title: '本地媒体库刮削模式',
                  subtitle: labsSettings.localLibraryScrapeMode ==
                          LibraryScrapeMode.tmdbId
                      ? '从文件夹 TMDB ID 直接识别；不读取视频内容'
                      : '使用 NipaPlay 原版扫描和匹配流程',
                  icon: Icons.folder_outlined,
                  phoneIcon: cupertino.CupertinoIcons.folder,
                  value: labsSettings.localLibraryScrapeMode ==
                      LibraryScrapeMode.tmdbId,
                  onChanged: (enabled) =>
                      labsSettings.setLocalLibraryScrapeMode(
                    enabled
                        ? LibraryScrapeMode.tmdbId
                        : LibraryScrapeMode.original,
                  ),
                ),
                AdaptiveSettingsTile.toggle(
                  title: 'WebDAV 媒体库刮削模式',
                  subtitle: labsSettings.webDavLibraryScrapeMode ==
                          LibraryScrapeMode.tmdbId
                      ? '从文件夹 TMDB ID 直接识别；扫描只请求目录元数据'
                      : '使用 NipaPlay 原版 WebDAV 刮削流程',
                  icon: Ionicons.cloud_outline,
                  phoneIcon: cupertino.CupertinoIcons.cloud,
                  value: labsSettings.webDavLibraryScrapeMode ==
                      LibraryScrapeMode.tmdbId,
                  onChanged: (enabled) =>
                      labsSettings.setWebDavLibraryScrapeMode(
                    enabled
                        ? LibraryScrapeMode.tmdbId
                        : LibraryScrapeMode.original,
                  ),
                ),
                AdaptiveSettingsTile.button(
                  title: 'TMDB 元数据访问令牌',
                  subtitle: labsSettings.tmdbReadAccessTokenConfigured
                      ? '已配置并保存在本设备；此凭据不会随媒体库同步到其他设备'
                      : 'TMDB ID 刮削需要凭据；Windows、Android 等设备需分别配置',
                  icon: Icons.key,
                  phoneIcon: cupertino.CupertinoIcons.lock,
                  trailingIcon: Ionicons.chevron_forward,
                  onTap: () => _configureTmdbToken(context, labsSettings),
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

  Future<void> _configureTmdbToken(
    BuildContext context,
    LabsSettingsProvider labsSettings,
  ) async {
    final controller = TextEditingController();
    try {
      final value = await showInViewDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('TMDB 元数据访问令牌'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '粘贴 TMDB API Read Access Token（推荐）或 32 位 v3 API Key。每台设备单独保存，凭据只保存在本机安全存储中。',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'TMDB API 凭据',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'This product uses the TMDB API but is not endorsed or certified by TMDB.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(''),
              child: const Text('清除令牌'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (value == null) return;
      await labsSettings.setTmdbReadAccessToken(value);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(value.trim().isEmpty ? '已清除 TMDB 令牌' : 'TMDB 令牌已安全保存')),
        );
      }
    } finally {
      controller.dispose();
    }
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
