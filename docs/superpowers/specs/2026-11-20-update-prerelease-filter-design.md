# 检查更新跳过预发布 Release · 设计文档

日期：2026-11-20
分支：`fix/update-prerelease-filter`
状态：已获用户批准（方案 1：修代码）

## 背景与根因

用户报告：v3.0.22（GitHub 上标记 Pre-release 的车机专项测试版）会被
≤3.0.21 正式版用户的「检查更新」检查到并提示升级。

根因：`AppUpdateService` 三级容灾通道对预发布的判定只靠 **tag 语法**
（`isStableVersionTag`：`^[vV]?\d+(\.\d+)*$`，拦 `-beta`/`-rc` 后缀），
而本仓库的发版习惯是**测试版 tag 用纯正式格式**（`v3.0.22`），预发布
靠 GitHub Release 对象的 `prerelease` 标志位区分。语法层永远拦不住
这类 tag：

| 通道 | 数据源 | 现状 |
|---|---|---|
| L1 API（主路径） | `/releases?per_page=30`，响应带 `prerelease`/`draft` 字段但**代码未读** | ❌ 漏 |
| L2 Atom（限流降级） | `releases.atom`，feed **不带预发布标志**，只有 tag 可依 | ❌ 漏 |
| L3 `/releases/latest` 302 | GitHub 端点**天然只指向最新正式版** | ✅ 无此问题 |

已核实的仓库实况（gh API）：v3.0.22 = `{prerelease: true, tag: "v3.0.22"}`，
latest 端点指向 v3.0.21。

## 修复设计

### 1. L1（主路径）：读标志位过滤

- 抽纯函数 `stableReleasesFromApi(List<dynamic>)`（`@visibleForTesting`，
  返回 `List<(Map<String,dynamic>, ReleaseEntrySummary)>`），在既有
  tag 语法过滤之外**加读 `prerelease == true || draft == true` 跳过**。
- 字段缺失（异常数据）时不拦，交给语法层兜底（保守不误杀）；
  `draft` 正常不出现在未鉴权响应里，过滤属零成本防御。
- `_fetchViaApi` 改为调用该纯函数，从返回的对里拆出原始 JSON 列表与
  摘要列表，其余选版/组装逻辑不动。

### 2. L2（Atom 降级）：天花板过滤

Atom feed 不带标志位，唯一可靠信号是「最新正式版」天花板：
- 抽 `_probeLatestReleaseTag()`：L3 的 302 重定向探测逻辑原样上移，
  返回 `String?`——null = 404（仓库无任何正式版）；网络/解析失败抛错。
- `_fetchViaRedirect`（L3）改用该探测函数，语义不变（404 →
  `暂无发布版本`；非正式语法 tag → `暂无正式发布版本`）。
- `_fetchViaAtomFeed`（L2）在解析 entries 后新增：
  1. 探测天花板 tag；**探测失败（网络抖动）→ rethrow 降级 L3**
     （fail-closed：宁漏一轮提示，不推错预发布；漏掉的下一轮自动
     检查自愈）；ceiling tag 非正式语法（防御场景）→ 同样抛错降级。
  2. ceiling = null（404，仓库仅剩预发布）→ 返回 null（确定无更新）。
  3. 纯函数 `dropPrereleasesAboveCeiling(entries, ceilingVersion)`
     （`@visibleForTesting`）：丢弃 semver 高于天花板的条目——高于
     最新正式版的 Atom 条目必为预发布（draft 不进 feed）。
  4. 过滤后非空 → 既有 `selectRelevantUpdate` 选版流程不变；
     过滤后为空（Atom 窗口内全是预发布）且 ceiling > 当前版本 →
     用 ceiling 组装 L3 式降级结果（无正文，「宁多提示不漏提示」）；
     ceiling ≤ 当前 → 返回 null。

### 3. L3：不动

只做探测函数上移重构，行为逐字等价。

## 不做的（YAGNI）

- 不改发版流程/不强求测试版 tag 带 `-beta` 后缀（客户端以标志位为准，
  两种命名习惯都兼容）；
- 不动已发布的 v3.0.22 Release（车机测试用户在用）；
- 不给 L3 加平台相关性过滤（维持既有 semver 兜底语义）。

## 测试设计

- 纯函数单测（新文件 `test/services/app_update_prerelease_filter_test.dart`，
  对齐 `app_update_fallback_test.dart` 的纯函数测试风格）：
  - `stableReleasesFromApi`：prerelease=true / draft=true / `-beta` 后缀 /
    空 tag / 非 map 全跳过；无标志位与显式 false 保留；字段缺失保守保留；
    返回对保留原始 JSON 与摘要。
  - `dropPrereleasesAboveCeiling`：高于天花板丢弃（v3.0.22 场景钉死）、
    等于/低于保留、全部高于 → 空列表。
- 实网探针（`app_update_live_probe_test.dart`，默认跳过）扩展一条
  手动验收断言：真实 API 数据过 `stableReleasesFromApi` 后不含任何
  `prerelease/draft` 条目；真实 Atom 条目过天花板过滤后不含
  v3.0.22（当前仓库唯一预发布）。

## 验收标准

1. 以 ≤3.0.21 客户端视角：L1/L2/L3 任一通道都不再把 v3.0.22 当更新提示；
2. 正式版更新提示行为不变（回归：全量测试绿）；
3. `flutter analyze` 0、`flutter test` 全绿；
4. 实网探针（手动）通过当前仓库数据验证。
