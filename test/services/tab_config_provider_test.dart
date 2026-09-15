import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../lib/providers/tab_config_provider.dart';

/// 主页 Tab 默认配置测试。
///
/// 需求：默认 Tab 顺序为 发现(discover) → 收藏(favorites) →
/// LaunchPad(launchpad) → 我的(user)；其余可选 Tab 默认隐藏。
void main() {
  testWidgets('全新安装：默认 Tab 为 发现/收藏/LaunchPad/我的，其余可选隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump(); // 等待异步 _load 完成
    await tester.pump();

    // 可见 Tab 顺序：发现 → 收藏 → LaunchPad → 我的
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'launchpad', 'user'],
      reason: '默认 Tab 顺序应为 发现/收藏/LaunchPad/我的',
    );
    // 本地音乐 / 封面流 / 私人FM 默认关闭
    expect(
      provider.hiddenTabs,
      containsAll(['library', 'coverflow', 'fm']),
      reason: '本地音乐/封面流/私人FM 默认隐藏',
    );
    expect(
      provider.hiddenTabs,
      containsAll(['search', 'charts', 'recognition']),
      reason: '搜索/排行榜/听歌识曲仍默认隐藏',
    );
  });

  testWidgets('重置默认：恢复 发现/收藏/LaunchPad/我的，其余可选隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 先把收藏手动隐藏，再重置，应恢复为显示
    await provider.toggleTabVisibility('favorites');
    expect(provider.hiddenTabs.contains('favorites'), isTrue, reason: '前置：收藏已手动隐藏');

    await provider.resetToDefault();
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'launchpad', 'user'],
      reason: '重置后默认 Tab 顺序应为 发现/收藏/LaunchPad/我的',
    );
    expect(
      provider.hiddenTabs,
      containsAll(['library', 'coverflow', 'fm']),
      reason: '重置后本地音乐/封面流/私人FM 默认隐藏',
    );
    expect(
      provider.hiddenTabs,
      containsAll(['search', 'charts', 'recognition']),
      reason: '重置后其余可选 Tab 默认隐藏',
    );
  });
}
