#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# راه‌اندازی TCP Proxy: ساخت رکورد Cloudflare + اینباند در پنل
#
# استفاده:
#   ./tcp-proxy-setup.sh <شماره> <هاست‌ریلوی> <پورت> [نام]
#
# مثال:
#   ./tcp-proxy-setup.sh 1 sakura.proxy.rlwy.net 52985 GERMANY
#
# نتیجه: کانفیگ روی tcp1.gucciyt.ccwu.cc:52985 ساخته می‌شود
#        (آدرس دامنه خودتان، نه آدرس Railway)
# ---------------------------------------------------------------------------
set -uo pipefail

CF_TOKEN="${CF_TOKEN:?متغیر CF_TOKEN تنظیم نشده}"
ZONE_ID="eb8377fb019faf90c46c433410c9140d"
BASE_DOMAIN="gucciyt.ccwu.cc"
PANEL="https://gucciyt.ccwu.cc/guccipanel"
PANEL_USER="${PANEL_USER:-admin}"
PANEL_PASS="${PANEL_PASS:-admin}"
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0'

N="${1:?شماره لازم است (1..10)}"
RLWY_HOST="${2:?هاست Railway لازم است}"
PORT="${3:?پورت لازم است}"
NAME="${4:-TCP-$N}"

SUB="tcp${N}"
FQDN="${SUB}.${BASE_DOMAIN}"
CJ=$(mktemp); trap 'rm -f "$CJ" /tmp/_tp.*' EXIT

say(){ printf '%s\n' "$*"; }

# ---------- ۱) رکورد DNS در Cloudflare ----------
say "[۱/۳] رکورد Cloudflare: ${FQDN} -> ${RLWY_HOST}"
EXIST=$(curl -s --max-time 25 -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${FQDN}" \
  | python3 -c "
import json,sys
r=(json.load(sys.stdin).get('result') or [])
print(r[0]['id'] if r else '')" 2>/dev/null)

BODY="{\"type\":\"CNAME\",\"name\":\"${SUB}\",\"content\":\"${RLWY_HOST}\",\"proxied\":false,\"ttl\":60}"

if [ -n "$EXIST" ]; then
  RES=$(curl -s --max-time 25 -X PUT \
    -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${EXIST}" \
    --data "$BODY")
else
  RES=$(curl -s --max-time 25 -X POST \
    -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    --data "$BODY")
fi
printf '%s' "$RES" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('      ',' موفق' if d.get('success') else ' خطا: '+str(d.get('errors'))[:80])"

# ---------- ۲) ورود به پنل ----------
say "[۲/۳] ورود به پنل"
C1=$(curl -s --max-time 20 -c "$CJ" -A "$UA" "$PANEL/csrf-token" \
     | python3 -c "import json,sys;print(json.load(sys.stdin)['obj'])" 2>/dev/null)
curl -s --max-time 20 -b "$CJ" -c "$CJ" -A "$UA" -X POST "$PANEL/login" \
  -H "X-CSRF-Token: $C1" -H 'Content-Type: application/x-www-form-urlencoded' \
  --data "username=${PANEL_USER}&password=${PANEL_PASS}" -o /dev/null
CSRF=$(curl -s --max-time 20 -b "$CJ" -c "$CJ" -A "$UA" "$PANEL/panel/csrf-token" \
       | python3 -c "import json,sys;print(json.load(sys.stdin)['obj'])" 2>/dev/null)
[ -z "$CSRF" ] && { say "      ورود ناموفق"; exit 1; }
say "      ورود موفق"

# ---------- ۳) ساخت اینباند ----------
say "[۳/۳] ساخت اینباند ${NAME} روی پورت ${PORT}"
SUBID=$(curl -s --max-time 20 -b "$CJ" -A "$UA" "$PANEL/panel/api/inbounds/list" \
  | python3 -c "
import json,sys
o=json.load(sys.stdin).get('obj') or []
for ib in o:
    s=ib['settings']
    if isinstance(s,str): s=json.loads(s)
    for c in s.get('clients',[]):
        print(c.get('subId','')); raise SystemExit
print('')" 2>/dev/null)

python3 - "$NAME" "$PORT" "$FQDN" "$SUBID" > /tmp/_tp.json <<'PY'
import json,uuid,secrets,string,sys
name,port,fqdn,subid=sys.argv[1],int(sys.argv[2]),sys.argv[3],sys.argv[4]
a=string.ascii_lowercase+string.digits
r=lambda n:''.join(secrets.choice(a) for _ in range(n))
if not subid: subid=r(16)
# externalProxy => آدرس کانفیگ دامنه شماست، نه آدرس Railway
ep=[{"forceTls":"none","dest":fqdn,"port":port,"remark":""}]
st={"network":"tcp","security":"none","externalProxy":ep,
    "tcpSettings":{"header":{"type":"none"}},
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
python3 -c "
import json
try:
    d=json.load(open('/tmp/_tp.res'))
    print('      ',' موفق' if d.get('success') else ' خطا: '+str(d.get('msg'))[:70])
except: print('       پاسخ نامعتبر')"

curl -s --max-time 30 -b "$CJ" -c "$CJ" -A "$UA" -X POST \
  -H "X-CSRF-Token: $CSRF" "$PANEL/panel/api/server/restartXrayService" -o /dev/null

say ""
say "آماده شد:"
say "   آدرس کانفیگ : ${FQDN}:${PORT}"
say "   نام         : ${NAME}"
say "   آدرس Railway در کانفیگ دیده نمی‌شود"
