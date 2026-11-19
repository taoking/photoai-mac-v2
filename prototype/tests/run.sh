#!/bin/zsh
# 在无界面 Chrome 里打开原型，注入 scenario-harness.html 走一遍典型场景，打印 PASS / FAIL。
# 出现 FAIL、EXC、脚本错误或拿不到结果时以非零退出。
# --self-test：额外注入一条必然失败的断言，确认上面这条退出规则本身有效（此时应以非零退出）。
set -euo pipefail
here=${0:A:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
extra=''
[[ "${1:-}" == "--self-test" ]] && extra='<script>window.__selfTestFail = true</script>'
python3 - "$here/../index.html" "$here/scenario-harness.html" "$work/test.html" "$extra" <<'PY'
import sys
page, harness, out, extra = sys.argv[1:]
s = open(page, encoding='utf-8').read()
h = open(harness, encoding='utf-8').read()
open(out, 'w', encoding='utf-8').write(s.replace('</body>', extra + h + '</body>'))
PY
output=$("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
  --window-size=1440,900 --virtual-time-budget=40000 --dump-dom "file://$work/test.html" 2>/dev/null \
  | python3 -c "import sys,re,html;s=sys.stdin.read();m=re.search(r'<pre id=\"__out\">(.*?)</pre>',s,re.S);print(html.unescape(m.group(1)) if m else 'NO OUTPUT')")
print -r -- "$output"
if [[ "$output" == "NO OUTPUT" ]] || print -r -- "$output" | grep -qE '^(FAIL|EXC)' || ! print -r -- "$output" | grep -qx 'ERRORS: \[\]'; then
  print -u2 "原型场景测试失败"
  exit 1
fi
