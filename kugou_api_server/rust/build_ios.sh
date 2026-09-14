#!/bin/bash
# 构建 iOS 用的 Rust 静态库并拷贝到 ios/Runner/rustlib/，
# Xcode 通过 OTHER_LDFLAGS 的 -force_load 链接进可执行文件。
# 用法：./build_ios.sh          # 真机 (aarch64-apple-ios)
#       ./build_ios.sh --sim   # 模拟器 (aarch64-apple-ios-sim)
set -e
cd "$(dirname "$0")"

if [ "$1" = "--sim" ]; then
  TARGET=aarch64-apple-ios-sim
else
  TARGET=aarch64-apple-ios
fi

rustup target add "$TARGET"
cargo build --release --target "$TARGET"

OUT_DIR="../ios/Runner/rustlib"
mkdir -p "$OUT_DIR"
cp "target/$TARGET/release/libkugou_server.a" "$OUT_DIR/"
echo "OK -> $OUT_DIR/libkugou_server.a ($TARGET)"
