#!/usr/bin/env bash
# 一次跑完装包、启动、打开工程、读状态，失败即报出哪一条断言没过。
# 用法: tools/verify.sh [目标地址]
#   目标地址缺省取 hvolt 配置里的 device_target；设备不在本机 USB 上时用 127.0.0.1:18710（Surface 转发）。
set -u

DEV="${1:-$(hvolt config get device_target 2>/dev/null | tail -1)}"
PKG="xyz.sudofree.hvolt.ide"
BUNDLE="$PKG"
LOGREL="projects/hvolt-ide-src/.hvolt/chat.jsonl"
BASE="/data/app/el2/100/base/$PKG/haps/entry/files"

fail=0
crashes_before=$(hvolt fault-log -d "${1:-127.0.0.1:18710}" -l 2>/dev/null | grep -c jscrash)
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
note() { printf '       %s\n' "$1"; }

echo "target: $DEV"
[ -n "$DEV" ] || { bad "没拿到目标地址"; exit 1; }

# 1 构建
if hvolt build >/tmp/verify-build.log 2>&1; then ok "build"; else bad "build（见 /tmp/verify-build.log）"; tail -5 /tmp/verify-build.log; fi

# 2 装包。经 tailnet 时 29 MB 单流要几分钟，改成分块并发送到 Surface，
#   再从 Surface 用局域网直连安装（实测 2.9 秒）。
SURFACE="xyzsu@100.64.0.2"
if [ "$DEV" = "127.0.0.1:18710" ]; then
  start=$(date +%s)
  rm -rf /tmp/vchunks && mkdir -p /tmp/vchunks
  gzip -1 -c output/entry-signed.hap > /tmp/vchunks/hap.gz
  (cd /tmp/vchunks && split -b 6m hap.gz c_)
  ssh -o BatchMode=yes "$SURFACE" "mkdir -p /c/Users/xyzsu/vhapc" >/dev/null 2>&1
  (cd /tmp/vchunks && ls c_* | xargs -P 4 -I{} scp -C -q {} "$SURFACE:C:/Users/xyzsu/vhapc/{}" >/dev/null 2>&1)
  note "传输 $(( $(date +%s) - start ))s（$(ls /tmp/vchunks/c_* | wc -l | tr -d ' ') 块并行，经 tailnet）"
  if ssh -o BatchMode=yes "$SURFACE" "cd /c/Users/xyzsu/vhapc && cat c_* > h.gz && gzip -df h.gz && hvolt push 192.168.1.2:8710 --hap 'C:/Users/xyzsu/vhapc/h'" 2>&1 | grep -q "Installed"; then
    ok "install（Surface 本地 192.168.1.2:8710）"
  else
    bad "install（Surface 侧失败）"
  fi
elif hvolt push "$DEV" --hap output/entry-signed.hap >/tmp/verify-push.log 2>&1; then
  ok "install"
else
  bad "install（见 /tmp/verify-push.log）"; tail -5 /tmp/verify-push.log
fi
hvolt start -d "$DEV" "$BUNDLE" >/dev/null 2>&1
sleep 3

# 3 进程存活
alive=$(hvolt shell -d "$DEV" "ps -ef|grep -c '[h]volt.ide'" 2>/dev/null | tail -1 | tr -d ' \r')
[ "${alive:-0}" -ge 1 ] 2>/dev/null && ok "进程存活 ($alive)" || bad "进程存活 (读到 ${alive:-空})"

# 4 崩溃记录：只算本次安装之后新增的，历史记录不清也不误报
crashes_now=$(hvolt fault-log -d "$DEV" -l 2>/dev/null | grep -c jscrash)
if [ "$crashes_now" -le "${crashes_before:-0}" ]; then
  ok "无新增 jscrash（历史 $crashes_now 条）"
else
  bad "新增 jscrash（$((crashes_now - ${crashes_before:-0})) 条）"
  hvolt fault-log -d "$DEV" -l 2>/dev/null | tail -3
fi

# 4b 界面上的页签切换由人操作，脚本不注入点击


# 5 启动后保持存活（不注入点击：界面操作由人做）
alive2=$(hvolt shell -d "$DEV" "ps -ef|grep -c '[h]volt.ide'" 2>/dev/null | tail -1 | tr -d ' \r')
[ "${alive2:-0}" -ge 1 ] 2>/dev/null && ok "启动后存活 ($alive2)" || bad "启动后存活 (读到 ${alive2:-空})"

# 6 会话文件：行数与 seq 必须严格是 0..n-1
# 先删：recv 失败时会留着上一次的文件，校验就成了在看旧内容
rm -f /tmp/verify-chat.jsonl
hvolt file recv -d "$DEV" "$BASE/$LOGREL" /tmp/verify-chat.jsonl >/dev/null 2>&1
if [ -s /tmp/verify-chat.jsonl ]; then
  python3 - <<'PY' || fail=$((fail+1))
import json, sys
rows = [l for l in open('/tmp/verify-chat.jsonl', encoding='utf-8').read().split('\n') if l.strip()]
bad = 0
for i, line in enumerate(rows):
    try:
        ev = json.loads(line)
    except Exception:
        print('  FAIL 第 %d 行不是 JSON' % (i + 1)); bad += 1; break
    if ev.get('seq') != i:
        print('  FAIL seq 不连续：第 %d 行期望 %d 得到 %s' % (i + 1, i, ev.get('seq'))); bad += 1; break
if not bad:
    print('  ok   会话文件 %d 行，seq 连续' % len(rows))
sys.exit(1 if bad else 0)
PY
else
  note "会话文件为空（还没发过消息），跳过 seq 校验"
fi

# 7 单测与解析
node test/session-model.test.ts >/tmp/verify-test.log 2>&1 && ok "session-model 测试" || { bad "session-model 测试"; tail -5 /tmp/verify-test.log; }
hvolt parse-report src/pages >/tmp/verify-parse.log 2>&1 && ok "parse-report" || { bad "parse-report"; tail -3 /tmp/verify-parse.log; }

echo
[ "$fail" = "0" ] && echo "全部通过" || echo "$fail 条未通过"
exit "$fail"
