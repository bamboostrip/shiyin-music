#!/usr/bin/env bash
# 在 Windows 侧的 WSL2 Ubuntu 内构建 Linux 桌面产物（开发验证用，CI 不走此脚本）。
#
# 用法（Git Bash / PowerShell 均可）：
#   wsl -d Ubuntu -e bash -lc "bash /mnt/d/AllCode/flutter/kgka_Music_hl_automotive/scripts/build_linux_wsl.sh"
#   可选参数：
#     --no-sync   跳过仓库重新拷贝（仅重跑构建）
#     --debug     构建 Debug 而非 Release
#
# 脚本内部动作：
#   1. 引导缺失工具链：ninja(静态二进制)、rustup(minimal stable)、
#      Flutter SDK(与仓库 CI 同版本的 Linux tarball)，全部装入 $HOME，无需 sudo；
#   2. 将仓库拷贝到 WSL 原生文件系统（~/build/kgka）再构建——
#      /mnt/* (DrvFS) 上跑 cargo LTO 极慢，勿直接在挂载盘内构建；
#   3. flutter build linux 并校验 bundle（libkugou_engine.so 是否入库等）。
#
# 依赖：WSL Ubuntu 已装 gcc/cmake/git/curl/xz（镜像默认或先前已装 libgtk-3-dev）。
#
# 已知网络受限提示：media_kit_libs_linux 的 CMake 会从 github codeload 下载
# mimalloc 源码并做 MD5 校验（5179c8f5...，即 codeload 归档的确切字节）。
# 国内网络对 codeload 的干扰会导致 "Integrity check failed" 反复失败，两种解法：
#   a. 预放正确字节：能通 codeload 时直接下载（或用已登录的 gh CLI：
#      gh api repos/microsoft/mimalloc/tarball/refs/tags/v2.1.2 > <tarball>，
#      该端点同样 302 到 codeload，字节一致），放到
#      build/linux/x64/release/mimalloc-2.1.2.tar.gz，CMake 检测到
#      MD5 匹配即跳过下载；
#   b. 本地降级：把 pub 缓存中该插件 CMakeLists 的
#      option(MIMALLOC_USE_STATIC_LIBS ... ON) 改为 OFF 并删除整个 build/
#      目录重跑（注意 option 旧值会被 CMakeCache 缓存，必须清缓存；
#      mimalloc 仅是分配器性能覆盖项，产物功能等价）。
# CI（GitHub runner）网络直达，不受影响。
# 另：只删 build/ 不删 .dart_tool 会导致 native_assets 缓存不一致
# （install 报 native_assets 目录缺失），需要干净构建时用 flutter clean。
set -euo pipefail

REPO_WIN_PATH="${REPO_WIN_PATH:-/mnt/d/AllCode/flutter/kgka_Music_hl_automotive}"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.44.8}"
BUILD_TYPE="release"
DO_SYNC=1

for arg in "$@"; do
  case "$arg" in
    --no-sync) DO_SYNC=0 ;;
    --debug)   BUILD_TYPE="debug" ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

DEV_DIR="$HOME/dev"
BUILD_DIR="$HOME/build/kgka"
NINJA_DIR="$DEV_DIR/ninja"
FLUTTER_DIR="$DEV_DIR/flutter-$FLUTTER_VERSION"
mkdir -p "$DEV_DIR"

log() { printf '\n\033[1;36m[build-linux-wsl] %s\033[0m\n' "$*"; }

# ---------- 1. ninja（Flutter linux 构建后端，静态单文件，免 sudo） ----------
if ! command -v ninja >/dev/null 2>&1 && [ ! -x "$NINJA_DIR/ninja" ]; then
  log "下载 ninja 静态二进制"
  mkdir -p "$NINJA_DIR"
  curl -fsSL -o /tmp/ninja-linux.zip \
    https://github.com/ninja-build/ninja/releases/latest/download/ninja-linux.zip
  # unzip 不一定安装，python3 ubuntu 必有
  python3 -m zipfile -e /tmp/ninja-linux.zip "$NINJA_DIR"
  chmod +x "$NINJA_DIR/ninja"
fi
[ -x "$NINJA_DIR/ninja" ] && export PATH="$NINJA_DIR:$PATH"
command -v ninja >/dev/null 2>&1 || { echo "ninja 不可用，无法继续" >&2; exit 1; }

# ---------- 2. rustup（rust_engine_build 的 cargo build） ----------
if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  log "安装 rustup (minimal stable)"
  curl -fsSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
fi
[ -x "$HOME/.cargo/bin/cargo" ] && export PATH="$HOME/.cargo/bin:$PATH"
# 中断过的 rustup 安装会留下 shim 甚至半损坏的工具链目录，必须以
# "能跑起来"为准；损坏时卸载重装（仅 rustup default 修不好缺 manifest）。
cargo --version >/dev/null 2>&1 || {
  log "cargo 不可用（rustup 工具链不完整/损坏），重装 stable"
  RUSTUP="$HOME/.cargo/bin/rustup"
  if [ ! -x "$RUSTUP" ]; then
    curl -fsSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  fi
  "$RUSTUP" toolchain uninstall stable >/dev/null 2>&1 || true
  "$RUSTUP" toolchain install stable --profile minimal
  "$RUSTUP" default stable
}
cargo --version >/dev/null 2>&1 || { echo "cargo 不可用，无法继续" >&2; exit 1; }

# ---------- 3. Flutter SDK（Linux 版，勿复用 /mnt/c 的 Windows SDK，会互写坏 cache） ----------
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  log "下载 Flutter $FLUTTER_VERSION (Linux stable)"
  RELEASES_JSON=$(curl -fsSL \
    https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)
  ARCHIVE=$(echo "$RELEASES_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
base = data['base_url']
target = None
stable_hash = data['current_release']['stable']
for r in data['releases']:
    if r.get('version') == '$FLUTTER_VERSION' and r.get('channel') == 'stable':
        target = r
        break
if target is None:
    for r in data['releases']:
        if r.get('hash') == stable_hash and r.get('channel') == 'stable':
            target = r
            print('警告: 未找到 $FLUTTER_VERSION，回退当前 stable '
                  + r.get('version', '?'), file=sys.stderr)
            break
if target is None:
    sys.exit('找不到可用的 stable release')
print(base + '/' + target['archive'])
")
  curl -fsSL -o /tmp/flutter.tar.xz "$ARCHIVE"
  rm -rf "$FLUTTER_DIR"
  mkdir -p "$FLUTTER_DIR"
  tar -xJf /tmp/flutter.tar.xz -C "$FLUTTER_DIR" --strip-components=1
fi
export PATH="$FLUTTER_DIR/bin:$PATH"
command -v flutter >/dev/null 2>&1 || { echo "flutter 不可用，无法继续" >&2; exit 1; }

# ---------- 4. 构建期系统依赖用户态 staging ----------
# 部分 Linux 插件的 CMake 硬依赖系统 dev 库（pkg-config 模块缺失直接
# FATAL_ERROR）：system_tray → ayatana-appindicator3-0.1、local_notifier →
# libnotify。无 root 时用 apt-get download + dpkg -x 解包到 ~/stage，并把
# staged 的 .pc 修正 prefix 后集中到 $STAGE/pc，经 PKG_CONFIG_PATH 优先
# 命中；staged 运行库经 LD_LIBRARY_PATH 参与链接与加载（见下方 export）。
STAGE="$HOME/stage"
STAGE_PKGS="libayatana-appindicator3-dev libayatana-appindicator3-1
libayatana-indicator3-7 libayatana-indicator3-dev
libayatana-ido3-0.4-0 libayatana-ido3-dev
libdbusmenu-gtk3-dev libdbusmenu-glib-dev
libdbusmenu-gtk3-4 libdbusmenu-glib4
libnotify-dev libnotify4"

if { ! pkg-config --exists ayatana-appindicator3-0.1 2>/dev/null && \
     ! pkg-config --exists appindicator3-0.1 2>/dev/null; } || \
   ! pkg-config --exists libnotify 2>/dev/null; then
  log "用户态 staging 构建期系统依赖（appindicator / libnotify，无 sudo）"
  mkdir -p "$STAGE/debs" "$STAGE/pc"
  ( cd "$STAGE/debs"
    for p in $STAGE_PKGS; do
      dpkg -s "$p" >/dev/null 2>&1 || apt-get download "$p" || echo "  跳过: $p"
    done )
  for deb in "$STAGE"/debs/*.deb; do
    [ -e "$deb" ] || continue
    dpkg -x "$deb" "$STAGE"
    rm -f "$deb"
  done
  # 把 staged .pc 的 prefix（原 /usr）改写到 staging 目录（个别字段写死
  # /usr 绝对路径的也一并兜住）。
  find "$STAGE/usr" -path '*/pkgconfig/*.pc' | while IFS= read -r pc; do
    sed -E "s#^prefix=.*#prefix=$STAGE/usr#; s#^(exec_prefix|libdir|includedir)=/usr#\1=$STAGE/usr#" \
      "$pc" > "$STAGE/pc/$(basename "$pc")"
  done
fi
if [ -d "$STAGE/usr/lib/x86_64-linux-gnu" ]; then
  export PKG_CONFIG_PATH="$STAGE/pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi

# ---------- 4.2 clang 用户态 staging ----------
# flutter build linux 向 CMake 硬编码注入 CC=clang/CXX=clang++
# （flutter_tools build_linux.dart，Process 环境与父合并、无法覆盖），
# 系统无 clang 且无 root 时同样用 apt-get download + dpkg -x staging。
if ! command -v clang >/dev/null 2>&1; then
  log "用户态 staging clang（flutter linux 构建硬依赖，无 sudo）"
  mkdir -p "$STAGE/debs"
  ( cd "$STAGE/debs" &&
    apt-cache depends --recurse --no-recommends --no-suggests \
      --no-conflicts --no-breaks --no-replaces --no-enhances --no-pre-depends clang \
      | grep -E '^\w' | sort -u > clang-closure.txt
    missing=""
    while IFS= read -r p; do
      dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
    done < clang-closure.txt
    for p in $missing; do
      apt-get download "$p" 2>/dev/null || echo "  跳过（虚拟包或不可下载）: $p"
    done )
  for deb in "$STAGE"/debs/*.deb; do
    [ -e "$deb" ] || continue
    dpkg -x "$deb" "$STAGE"
    rm -f "$deb"
  done
fi
export PATH="$STAGE/usr/bin:$PATH"
hash -r 2>/dev/null || true
clang --version >/dev/null 2>&1 || { echo "clang staging 失败" >&2; exit 1; }
log "使用编译器: $(clang --version | head -1)"
# staged clang 的私有库（libLLVM/libclang-cpp 在 llvm-N/lib 下）需要显式指路。
LLVM_LIB=$(ls -d "$STAGE"/usr/lib/llvm-*/lib 2>/dev/null | head -1)
export LD_LIBRARY_PATH="${LLVM_LIB:+$LLVM_LIB:}$STAGE/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ---------- 5. 仓库拷贝到原生 fs（排除大目录；保留 packages/ 本地补丁包） ----------
if [ "$DO_SYNC" = "1" ]; then
  log "同步仓库 $REPO_WIN_PATH -> $BUILD_DIR"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  tar -C "$REPO_WIN_PATH" \
    --exclude=./build --exclude=./.dart_tool --exclude=./rust/target \
    --exclude=./.git --exclude=./screenshots \
    -cf - . | tar -C "$BUILD_DIR" -xf -
else
  log "跳过仓库同步 (--no-sync)"
fi

# ---------- 6. 构建 ----------
cd "$BUILD_DIR"
flutter config --no-analytics >/dev/null 2>&1 || true
log "flutter pub get"
# 国内网络直连 pub.dev 常握手失败：先探测，不通自动切官方中国镜像，
# 仍失败则用本地 pub 缓存离线解析（依赖未变时必然可离线）。
if ! curl -fsSI --max-time 8 https://pub.dev >/dev/null 2>&1; then
  log "pub.dev 不可达，切换中国镜像 pub.flutter-io.cn"
  export PUB_HOSTED_URL=https://pub.flutter-io.cn
  export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
fi
flutter pub get || flutter pub get --offline || { echo "pub get 失败" >&2; exit 1; }
log "flutter build linux --$BUILD_TYPE"
flutter build linux "--$BUILD_TYPE"

# ---------- 7. 产物校验 ----------
BUNDLE="$BUILD_DIR/build/linux/x64/$BUILD_TYPE/bundle"
log "构建完成，校验 bundle: $BUNDLE"
ls -la "$BUNDLE"
echo "--- bundle/lib ---"
ls -la "$BUNDLE/lib"
for f in "$BUNDLE/kgka_music_hl" "$BUNDLE/lib/libkugou_engine.so" "$BUNDLE/lib/libflutter_linux_gtk.so"; do
  [ -f "$f" ] || { echo "缺少关键产物: $f" >&2; exit 1; }
done
echo "--- ldd 未解析依赖检查 ---"
LDD_MISS=$(find "$BUNDLE" -maxdepth 2 -type f \( -name '*.so' -o -name 'kgka_music_hl' \) \
  -exec ldd {} \; 2>/dev/null | grep "not found" || true)
if [ -n "$LDD_MISS" ]; then
  echo "警告：存在未解析的动态依赖（libmpv 等运行期依赖属预期，其余不应出现）："
  echo "$LDD_MISS"
fi
log "OK: $BUNDLE"
