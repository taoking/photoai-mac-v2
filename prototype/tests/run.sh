#!/bin/zsh
# 在无界面 Chrome 里打开原型，注入 scenario-harness.html 走一遍典型场景，打印 PASS / FAIL。
set -euo pipefail
here=${0:A:h}
work=$(mktemp -d)
python3 - "$here/../index.html" "$here/scenario-harness.html" "$work/test.html" <<'PY'
import sys
page, harness, out = sys.argv[1:]
s = open(page, encoding='utf-8').read()
h = open(harness, encoding='utf-8').read()
open(out, 'w', encoding='utf-8').write(s.replace('</body>', h + '</body>'))
PY
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
  --window-size=1440,900 --virtual-time-budget=30000 --dump-dom "file://$work/test.html" 2>/dev/null \
  | python3 -c "import sys,re,html;s=sys.stdin.read();m=re.search(r'<pre id=\"__out\">(.*?)</pre>',s,re.S);print(html.unescape(m.group(1)) if m else 'NO OUTPUT')"
rm -rf "$work"
