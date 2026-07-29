#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# راه‌اندازی TCP Proxy ریلوی روی دامنه شخصی
#
# استفاده:
#   CF_TOKEN=... ./tcp-proxy-setup.sh <شماره> <هاست> <پورت‌پروکسی> <پورت‌داخلی> [نام]
#
# مثال:
#   ./tcp-proxy-setup.sh 1 thomas.proxy.rlwy.net 11190 30126 GUCCI-1
#
# نتیجه: کانفیگ روی tcp1.gucciyt.ccwu.cc:11190
#        آدرس ریلوی در کانفیگ دیده نمی‌شود.
#
# توضیح دو پورت:
#   پورت‌پروکسی  = پورتی که Railway از بیرون باز کرده (کاربر به آن وصل می‌شود)
#   پورت‌داخلی   = پورتی که Railway به آن فوروارد می‌کند (Xray روی آن گوش می‌دهد)
# ---------------------------------------------------------------------------
set -uo pipefail

CF_TOKEN="${CF_TOKEN:?متغیر CF_TOKEN تنظیم نشده}"
ZONE_ID="eb8377fb019faf90c46c433410c9140d"
BASE_DOMAIN="gucciyt.ccwu.cc"
PANEL="https://gucciyt.ccwu.cc/guccipanel"
PANEL_USER="${PANEL_USER:-admin}"
PANEL_PASS="${PANEL_PASS:-admin}"
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0'

N="${1:?شماره لازم است}"
RLWY_HOST="${2:?هاست ریلوی لازم است}"
PROXY_PORT="${3:?پورت پروکسی لازم است}"
LOCAL_PORT="${4:?پورت داخلی لازم است}"
NAME="${5:-TCP-$N}"

SUB="tcp${N}"
FQDN="${SUB}.${BASE_DOMAIN}"
CJ=$(mktemp); trap 'rm -f "$CJ" /tmp/_tp.*' EXIT
say(){ printf '%s\n' "$*"; }

# ---------- ۱) رکورد DNS ----------
say "[۱/۴] رکورد Cloudflare: ${FQDN} -> ${RLWY_HOST}"
EXIST=$(curl -s --max-time 25 -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${FQDN}" \
  | python3 -c "
import json,sys
r=(json.load(sys.stdin).get('result') or [])
print(r[0]['id'] if r else '')" 2>/dev/null)

BODY="{\"type\":\"CNAME\",\"name\":\"${SUB}\",\"content\":\"${RLWY_HOST}\",\"proxied\":false,\"ttl\":60}"
if [ -n "$EXIST" ]; then
  RES=$(curl -s --max-time 25 -X PUT -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${EXIST}" --data "$BODY")
else
  RES=$(curl -s --max-time 25 -X POST -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" --data "$BODY")
fi
printf '%s' "$RES" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('       موفق' if d.get('success') else '       خطا: '+str(d.get('errors'))[:80])"

# ---------- ۲) ورود ----------
say "[۲/۴] ورود به پنل"
C1=$(curl -s --max-time 20 -c "$CJ" -A "$UA" "$PANEL/csrf-token" \
     | python3 -c "import json,sys;print(json.load(sys.stdin)['obj'])" 2>/dev/null)
curl -s --max-time 20 -b "$CJ" -c "$CJ" -A "$UA" -X POST "$PANEL/login" \
  -H "X-CSRF-Token: $C1" -H 'Content-Type: application/x-www-form-urlencoded' \
  --data "username=${PANEL_USER}&password=${PANEL_PASS}" -o /dev/null
CSRF=$(curl -s --max-time 20 -b "$CJ" -c "$CJ" -A "$UA" "$PANEL/panel/csrf-token" \
       | python3 -c "import json,sys;print(json.load(sys.stdin)['obj'])" 2>/dev/null)
[ -z "$CSRF" ] && { say "       ورود ناموفق"; exit 1; }
say "       موفق"

# ---------- ۳) اینباند ----------
say "[۳/۴] اینباند ${NAME} روی پورت داخلی ${LOCAL_PORT}"
SUBID=$(curl -s --max-time 20 -b "$CJ" -A "$UA" "$PANEL/panel/api/inbounds/list" \
  | python3 -c "
import json,sys
for ib in (json.load(sys.stdin).get('obj') or []):
    s=ib['settings']
    if isinstance(s,str): s=json.loads(s)
    for c in s.get('clients',[]):
        print(c.get('subId','')); raise SystemExit
print('')" 2>/dev/null)

python3 - "$NAME" "$LOCAL_PORT" "$SUBID" > /tmp/_tp.json <<'PY'
import json,uuid,secrets,string,sys
name,port,subid=sys.argv[1],int(sys.argv[2]),sys.argv[3]
a=string.ascii_lowercase+string.digits
r=lambda n:''.join(secrets.choice(a) for _ in range(n))
if not subid: subid=r(16)
st={"network":"tcp","security":"none","tcpSettings":{"header":{"type":"none"}},
    "sockopt":{"tcpFastOpen":True,"tcpNoDelay":True,"tcpcongestion":"bbr"}}
cl={"id":str(uuid.uuid4()),"email":name.lower().replace('-','_'),"enable":True,
    "expiryTime":0,"limitIp":2,"totalGB":0,"tgId":0,"subId":subid,"reset":0,
    "comment":"⚡ 10/10 · بدون محدودیت","security":"auto",
    "password":r(16),"auth":r(16)}
print(json.dumps({"remark":name,"enable":True,"port":port,"listen":"",
  "protocol":"vless","expiryTime":0,"total":0,
  "settings":json.dumps({"clients":[cl],"decryption":"none","fallbacks":[]}),
  "streamSettings":json.dumps(st),
  "sniffing":json.dumps({"enabled":False,"destOverride":["http","tls"]})}))
PY

curl -s --max-time 30 -b "$CJ" -c "$CJ" -A "$UA" -X POST \
  -H "X-CSRF-Token: $CSRF" -H 'Content-Type: application/json' \
  --data @/tmp/_tp.json "$PANEL/panel/api/inbounds/add" -o /tmp/_tp.res
INB_ID=$(python3 -c "
import json
try:
    d=json.load(open('/tmp/_tp.res'))
    print(d['obj']['id'] if d.get('success') and d.get('obj') else '')
except: print('')")
if [ -n "$INB_ID" ]; then say "       موفق (id=$INB_ID)"; else say "       خطا"; exit 1; fi

# ---------- ۴) میزبان: پورت بیرونی را در کانفیگ می‌نشاند ----------
say "[۴/۴] میزبان ${FQDN}:${PROXY_PORT}"
python3 - "$INB_ID" "$FQDN" "$PROXY_PORT" "$NAME" > /tmp/_tp.host <<'PY'
import json,sys
iid,fqdn,port,name=int(sys.argv[1]),sys.argv[2],int(sys.argv[3]),sys.argv[4]
print(json.dumps({"groupId":"","inboundIds":[iid],
  "hosts":[f"{fqdn}:{port}"],"sortOrder":0,"remark":name,
  "serverDescription":"","isDisabled":False,"isHidden":False,
  "tags":[],"port":port,"security":"same"}))
PY
curl -s --max-time 30 -b "$CJ" -c "$CJ" -A "$UA" -X POST \
  -H "X-CSRF-Token: $CSRF" -H 'Content-Type: application/json' \
  --data @/tmp/_tp.host "$PANEL/panel/api/hosts/add" -o /tmp/_tp.hres
python3 -c "
import json
try:
    d=json.load(open('/tmp/_tp.hres'))
    print('       موفق' if d.get('success') else '       خطا: '+str(d.get('msg'))[:60])
except: print('       ?')"

curl -s --max-time 30 -b "$CJ" -c "$CJ" -A "$UA" -X POST \
  -H "X-CSRF-Token: $CSRF" "$PANEL/panel/api/server/restartXrayService" -o /dev/null

say ""
say "آماده شد:"
say "   کانفیگ کاربر : ${FQDN}:${PROXY_PORT}"
say "   پورت داخلی   : ${LOCAL_PORT}"
say "   آدرس ریلوی در کانفیگ دیده نمی‌شود"
