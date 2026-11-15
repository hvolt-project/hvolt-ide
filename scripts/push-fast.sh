#!/bin/sh
# 经跳板机装包：mac →(并行分片 scp)→ Surface →(局域网)→ 设备。
#
# 为什么不用 hvolt push -d 127.0.0.1:18710：那是单流走 tailnet 隧道，2026-11-14 实测
# 30.78 MB 用了 1218 s（≈25 KB/s）。同样的包走跳板：4 片并行 scp 125 s（≈171 KB/s），
# Surface 局域网安装 8 s，合计约 2 分 20 秒。
#
# 跳板机上需要 hvolt 的 Windows 版（服务器 ~/work/hvolt 交叉编译 x86_64-pc-windows-gnu 得到）。
# 全程只用 hvolt 自有通道，不出现任何 hdc 调用。
#
# 用法：scripts/push-fast.sh <hap> [surface] [lan-device] [jobs]
set -e
hap=$1
[ -n "$hap" ] || { echo "usage: $0 <hap> [surface] [lan-device] [jobs]" >&2; exit 2; }
surface=${2:-xyzsu@100.64.0.2}
device=${3:-192.168.1.2:8710}
jobs=${4:-4}
[ -f "$hap" ] || { echo "no such hap: $hap" >&2; exit 2; }

name=$(basename "$hap")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "== 1/4 压缩与切片 =="
cp "$hap" "$work/$name"
gzip -1 "$work/$name"
split -b 6m "$work/$name.gz" "$work/part."
parts=$(ls "$work"/part.* | wc -l | tr -d ' ')
echo "   $parts 片，$(stat -f %z "$work/$name.gz") 字节（压缩后）"

echo "== 2/4 并行传到跳板 =="
start=$(date +%s)
ssh "$surface" 'mkdir -p hvtpush'
ls "$work"/part.* | xargs -P "$jobs" -I{} scp -q -o BatchMode=yes {} "$surface:hvtpush/"
echo "   scp 耗时 $(( $(date +%s) - start ))s"

echo "== 3/4 跳板上合并并安装 =="
ssh "$surface" "cd hvtpush && rm -f $name && cat part.* > $name.gz && gunzip -f $name.gz && \
  ./hvolt.exe push -d $device --hap $name 2>&1 | tail -2 && \
  ./hvolt.exe start -d $device xyz.sudofree.hvolt.ide 2>&1 | tail -1"
echo "   合计 $(( $(date +%s) - start ))s"
