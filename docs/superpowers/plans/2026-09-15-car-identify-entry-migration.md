# Car Identify Entry Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the music identify icon from the car mode home top bar to prevent accidental clicks, and add a 46px "识曲" tonal button in the car mode search page header.

**Architecture:** 
- In `app_shell.dart` (`_buildCarTopNavBar`), simplify the search pill button into a pure search entrance without the identify icon and divider.
- In `search_page.dart` (`_buildCarSearchHeader`), insert a 46px `FilledButton.tonalIcon` for music identify next to the search button when `IdentifyService.isSupported`.
- In `test/ui/widgets/identify_entries_test.dart`, add widget tests for car mode search header and home car navigation bar.

**Tech Stack:** Flutter / Dart, Material 3, `IdentifyService`.

## Global Constraints
- Only render identify buttons when `IdentifyService.isSupported` is true.
- Car mode UI height should align with 46px height and 23px border radius.
- Re-use `_openIdentify(context)` for consistent debouncing (`tryConsumeEntry`) and lifecycle management.

---

### Task 1: Update Car Mode Top Navigation Bar in Home Page

**Files:**
- Modify: `lib/ui/pages/app_shell.dart:381-481`

**Interfaces:**
- Consumes: `Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchPage(...)))`
- Produces: Simplified search capsule button in `_buildCarTopNavBar`.

- [ ] **Step 1: Inspect and update `_buildCarTopNavBar` in `lib/ui/pages/app_shell.dart`**

Modify the search container to be wrapped directly in a single `GestureDetector`:
```dart
          // Search Pill Button — 纯搜索入口，点击直达搜索页，杜绝首页误触
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchPage(
                  api: widget.api,
                  auth: widget.auth,
                  player: widget.player,
                ),
              ),
            ),
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: isDark
                    ? colorScheme.surfaceContainerHighest
                    : colorScheme.surfaceContainerHighest.withValues(
                        alpha: .54,
                      ),
                borderRadius: BorderRadius.circular(23),
                border: Border.all(
                  color: isDark
                      ? colorScheme.outlineVariant.withValues(alpha: .85)
                      : colorScheme.outlineVariant.withValues(alpha: .45),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.search_rounded,
                    color: isDark
                        ? colorScheme.onSurface.withValues(alpha: .92)
                        : colorScheme.onSurfaceVariant,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '搜索',
                    style: TextStyle(
                      color: isDark
                          ? colorScheme.onSurface.withValues(alpha: .92)
                          : colorScheme.onSurfaceVariant,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
```

- [ ] **Step 2: Verify compilation and analysis for `app_shell.dart`**

Run: `flutter analyze lib/ui/pages/app_shell.dart`
Expected: No errors.

- [ ] **Step 3: Commit Task 1**

```bash
git add lib/ui/pages/app_shell.dart
git commit -m "refactor: simplify car mode home top bar search pill and remove identify icon"
```

---

### Task 2: Add Identify Button to Car Search Page Header

**Files:**
- Modify: `lib/ui/pages/search_page.dart:367-463`

**Interfaces:**
- Consumes: `IdentifyService.isSupported`, `_openIdentify(BuildContext context)`
- Produces: 46px "识曲" `FilledButton.tonalIcon` in `_buildCarSearchHeader`.

- [ ] **Step 1: Update `_buildCarSearchHeader` in `lib/ui/pages/search_page.dart`**

Add the "识曲" tonal button next to the "搜索" button:
```dart
        if (IdentifyService.isSupported) ...[
          const SizedBox(width: 10),
          SizedBox(
            height: 46,
            child: FilledButton.tonalIcon(
              onPressed: () => _openIdentify(context),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(23),
                ),
              ),
              icon: Icon(
                Icons.graphic_eq_rounded,
                size: 20,
                color: colorScheme.primary,
              ),
              label: Text(
                '识曲',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? colorScheme.onSurface.withValues(alpha: .92)
                      : colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(width: 10),
        SizedBox(
          height: 46,
          child: FilledButton.tonal(
            onPressed: _onSubmit,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(23),
              ),
            ),
            child: const Text(
              '搜索',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
```

- [ ] **Step 2: Verify compilation and analysis for `search_page.dart`**

Run: `flutter analyze lib/ui/pages/search_page.dart`
Expected: No errors.

- [ ] **Step 3: Commit Task 2**

```bash
git add lib/ui/pages/search_page.dart
git commit -m "feat: add identify button to car search page header"
```

---

### Task 3: Add and Update Widget Tests

**Files:**
- Modify: `test/ui/widgets/identify_entries_test.dart`

**Interfaces:**
- Consumes: `SearchPage`, `app_shell.dart`, `IdentifyService`
- Produces: Complete widget test suite covering car mode search header and home top nav bar.

- [ ] **Step 1: Add widget test for car mode search header and verify home top bar**

In `test/ui/widgets/identify_entries_test.dart`, add:
```dart
  group('Car Mode 识曲入口', () {
    testWidgets('车机模式搜索页渲染听歌识曲按钮并能触发点击', (tester) async {
      if (!IdentifyService.isSupported) return;

      final player = _FakePlayer();
      final api = _FakeMusicApi();
      final auth = _FakeAuthController();

      // 设置横屏尺寸以激活 isLandscape 与 carMode
      tester.view.physicalSize = const Size(1024, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      ThemeController.instance.setCarModeEnabled(true);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPage(
              api: api,
              auth: auth,
              player: player,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final identifyBtn = find.widgetWithText(FilledButton, '识曲');
      expect(identifyBtn, findsOneWidget);
      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    });
  });
```

- [ ] **Step 2: Run all tests to verify**

Run: `flutter test test/ui/widgets/identify_entries_test.dart`
Expected: All tests pass.

- [ ] **Step 3: Commit Task 3**

```bash
git add test/ui/widgets/identify_entries_test.dart
git commit -m "test: add car mode identify entry widget tests"
```
