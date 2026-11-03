#!/usr/bin/env bash
# 为 iOS 构建 Rust 引擎静态库（配 project.pbxproj 里 Runner target 的
# OTHER_LDFLAGS 与 ios/Flutter/*.xcconfig 的 DEAD_CODE_STRIPPING）。
#
# 为什么需要这个脚本：iOS 不允许 App 随便 dlopen 自带的 dylib，所以 Rust 不打
# dylib/framework，而是以静态库直接链进 Runner 主二进制；pbxproj 的
# OTHER_LDFLAGS 里写死了产物路径 rust/target/<target>/release/。也就是说
# flutter build/run 之前必须先跑一次本脚本，否则链接期报 "file not found"。
# CI 里由 .github/workflows/build-ios.yml 直接执行等价命令（不调用本脚本，
# 便于在日志里分步定位）。
#
# 用法（仅 macOS，iOS 构建离不开 Xcode 工具链）：
#   bash scripts/build_rust_ios.sh          # 只构建真机 arm64（CI 用这个）
#   bash scripts/build_rust_ios.sh --sim    # 额外构建 Apple Silicon 模拟器版
#
# 前置：Xcode 命令行工具（xcode-select --install）与 rustup。
set -euo pipefail

cd "$(dirname "$0")/.."

targets=(aarch64-apple-ios)
if [[ "${1:-}" == "--sim" ]]; then
  targets+=(aarch64-apple-ios-sim)
fi

for target in "${targets[@]}"; do
  echo "==> rustup target add ${target}"
  rustup target add "${target}" >/dev/null
  echo "==> cargo build --release --target ${target}"
  cargo build --release --target "${target}" --manifest-path rust/Cargo.toml

  lib="rust/target/${target}/release/libkugou_engine.a"
  if [[ ! -f "${lib}" ]]; then
    echo "❌ 未生成 ${lib}" >&2
    exit 1
  fi
  echo "✅ ${lib} ($(du -h "${lib}" | cut -f1))"
done

echo "完成：现在可以 flutter build ios / flutter run（模拟器请先加 --sim）。"
