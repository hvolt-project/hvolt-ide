#!/bin/sh
# 重新编译 app/navi/cpp 下的两个 so，写回 app/src/libs/arm64-v8a。
#
# 这两个库不进 CMakeLists：libnavi.so 是 QuickJS + libgit2 静态链进 NAPI 模块，
# libnavi_ssh.so 是 libssh2/mbedTLS 的独立 so。设备侧由 ArkTS 直接 import 名字，
# 所以文件名和导出符号都不能变。
#
# 工具链是 HarmonyOS SDK 的 clang（aarch64-unknown-linux-ohos-clang++），不在桌面 PATH 里。
# 依次尝试：$HVOLT_OHOS_SDK、DevEco 自带 SDK、~/.hvolt/sdk 里最新的版本目录。
#
# 用法：scripts/build-navi.sh [--no-strip]
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cpp="$root/app/navi/cpp"
out="$root/app/src/libs/arm64-v8a"
[ -d "$cpp" ] || { echo "no $cpp" >&2; exit 2; }

strip=1
for arg in "$@"; do
  [ "$arg" = "--no-strip" ] && strip=0
done

# $1 = SDK native 目录（含 llvm/bin 与 sysroot）
pick_sdk() {
  for candidate in "${HVOLT_OHOS_SDK:-}" \
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native" \
    "$HOME/.hvolt/sdk/v26.0.0.38/openharmony/native"; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate/llvm/bin/aarch64-unknown-linux-ohos-clang++" ]; then
      echo "$candidate"
      return 0
    fi
  done
  # 版本目录不固定时取最新一个
  for dir in $(ls -d "$HOME"/.hvolt/sdk/*/openharmony/native 2>/dev/null | sort -r); do
    if [ -x "$dir/llvm/bin/aarch64-unknown-linux-ohos-clang++" ]; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}

sdk=$(pick_sdk) || {
  echo "找不到 HarmonyOS SDK 的 native 目录；设 HVOLT_OHOS_SDK 指向它" >&2
  exit 3
}
cxx="$sdk/llvm/bin/aarch64-unknown-linux-ohos-clang++"
strip_tool="$sdk/llvm/bin/llvm-strip"
sysroot="$sdk/sysroot"
[ -x "$strip_tool" ] || strip_tool=$(command -v llvm-strip || true)

common="-target aarch64-linux-ohos --sysroot=$sysroot -fPIC -O2 -std=c++17"

echo "== SDK: $sdk"

# libnavi.so：5 个源文件 + QuickJS 静态库 + libgit2 动态库
echo "== libnavi.so"
# shellcheck disable=SC2086
"$cxx" $common \
  -I"$cpp" -I"$cpp/quickjs" -I"$cpp/libgit2" \
  -shared -o "$out/libnavi.so" \
  "$cpp/napi_init.cpp" "$cpp/sandbox_sh.cpp" "$cpp/js_eval.cpp" \
  "$cpp/git_napi.cpp" "$cpp/rewind_napi.cpp" \
  "$cpp/quickjs/libquickjs.a" "$out/libgit2.so" \
  -lace_napi.z -lhilog_ndk.z -ldl -lm

# libnavi_ssh.so：只编 ssh_napi.cpp，libssh2 与 mbedTLS 是它自己的静态库
echo "== libnavi_ssh.so"
# shellcheck disable=SC2086
"$cxx" $common \
  -I"$cpp/ssh/include" \
  -shared -o "$out/libnavi_ssh.so" \
  "$cpp/ssh_napi.cpp" \
  "$cpp/ssh/libssh2.a" "$cpp/ssh/libmbedtls.a" \
  "$cpp/ssh/libmbedx509.a" "$cpp/ssh/libmbedcrypto.a" \
  -lace_napi.z -lhilog_ndk.z -ldl -lm

if [ "$strip" = 1 ]; then
  [ -n "$strip_tool" ] || { echo "没有 llvm-strip；用 --no-strip 跳过" >&2; exit 4; }
  "$strip_tool" --strip-unneeded "$out/libnavi.so" "$out/libnavi_ssh.so"
  echo "== stripped"
fi

# 导出符号是设备侧 import 的依据，少一个就是运行期报错而不是构建期
for so in libnavi.so libnavi_ssh.so; do
  size=$(wc -c <"$out/$so" | tr -d ' ')
  echo "   $so $size 字节"
done
if command -v nm >/dev/null 2>&1; then
  n=$(nm -D --defined-only "$out/libnavi.so" 2>/dev/null | wc -l | tr -d ' ')
  s=$(nm -D --defined-only "$out/libnavi_ssh.so" 2>/dev/null | grep -c "RegisterNaviSsh" || true)
  echo "   libnavi.so 导出 $n 个符号；libnavi_ssh.so RegisterNaviSsh=${s}"
fi