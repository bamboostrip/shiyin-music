#!/usr/bin/env bash
# 把 AppIndicator / keybinder 运行期依赖收进 Linux 便携包，并修正插件 RUNPATH，
# 使解压后直接 `./ShiYinMusic` 即可在非 Debian 系（Arch/CachyOS、Fedora 等）启动。
#
# 背景：CI 在 Ubuntu 22.04 构建，hotkey_manager_linux / system_tray 插件的
# DT_NEEDED 记录的是 Debian 系 soname（libkeybinder-3.0.so.0、
# libayatana-indicator3.so.7、libayatana-ido3-0.4.so.0 等）。Arch 上这些库或
# 在 AUR、或不被默认安装，动态加载器在启动主程序时直接报
# "error while loading shared libraries" 而退出；插件自身 RUNPATH 是构建机
# 绝对路径，搜不到 bundle/lib 里的兄弟库，因此需一并改成 $ORIGIN。
#
# 用法：bundle_linux_runtime.sh <bundle-dir>
#   CI：build-linux.yml 在 Stage portable directory 之后调用；
#   本地：bash scripts/bundle_linux_runtime.sh build/linux/x64/release/bundle
#
# 依赖：当前系统已装齐构建期 dev 包（CI 的 apt 步骤已保证），patchelf 可用。
set -euo pipefail

BUNDLE_DIR="${1:?用法: bundle_linux_runtime.sh <bundle-dir>}"
[ -d "$BUNDLE_DIR/lib" ] || { echo "不是有效的 bundle: $BUNDLE_DIR" >&2; exit 1; }

PATCHELF="${PATCHELF:-patchelf}"
command -v "$PATCHELF" >/dev/null 2>&1 || { echo "缺少 patchelf" >&2; exit 1; }

# 这些 soname 由 build-linux.yml 的 apt 构建依赖（*-dev）拉入，但运行期在
# Arch/Fedora 上并不保证存在，故随包携带。其余系统库（GTK3/glib/X11/ALSA/
# libmpv）各桌面环境通用，仍由系统提供。
RUNTIME_LIBS=(
  libkeybinder-3.0.so.0
  libayatana-appindicator3.so.1
  libayatana-indicator3.so.7
  libayatana-ido3-0.4.so.0
  libdbusmenu-glib.so.4
  libdbusmenu-gtk3.so.4
  libnotify.so.4
)

find_lib() {
  # 不提前 exit，避免 ldconfig 因 SIGPIPE 刷错误日志。
  ldconfig -p | awk -v n="$1" '$1 == n && !seen { print $NF; seen = 1 }'
}

for soname in "${RUNTIME_LIBS[@]}"; do
  src="$(find_lib "$soname" || true)"
  [ -n "$src" ] || {
    echo "系统缺少运行期依赖: $soname（请检查 apt 构建依赖是否装齐）" >&2
    exit 1
  }
  # -L 解引用符号链接，避免把指向构建机绝对路径/相对链拷进包里失效。
  cp -aL "$src" "$BUNDLE_DIR/lib/$soname"
done

# 插件与刚拷入的库 RUNPATH 指向构建机路径；统一改为 $ORIGIN（都在 lib/ 内）。
for f in "$BUNDLE_DIR"/lib/*.so; do
  "$PATCHELF" --set-rpath '$ORIGIN' "$f"
done

# 校验：包内所有 ELF 不得有未解析动态依赖。ldd 需带 bundle/lib，否则刚收拢
# 进来的兄弟库会被误报；libjvm.so 是 libdartjni.so 运行期 dlopen 的可选依赖，
# 由用户机器的 JRE 提供，不属于打包缺失。
missing="$(LD_LIBRARY_PATH="$BUNDLE_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  find "$BUNDLE_DIR" -maxdepth 2 -type f \( -name '*.so*' -o -name 'ShiYinMusic' \) \
    -exec ldd {} \; 2>/dev/null | grep 'not found' | grep -v 'libjvm.so' || true)"
if [ -n "$missing" ]; then
  echo "bundle 存在未解析依赖：" >&2
  echo "$missing" >&2
  exit 1
fi

echo "已收拢 ${#RUNTIME_LIBS[@]} 个运行期依赖到 $BUNDLE_DIR/lib，并修正 RUNPATH"
