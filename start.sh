#!/bin/bash
set -e

echo "🚀 Starting X-UI + nginx reverse proxy..."

# nginx همیشه روی پورت ثابت 2053 گوش می‌دهد
export NGINX_PORT=2053

cd /usr/local/x-ui

# ---------------------------------------------------------------
# fail2ban: پنل فیلد IP Limit را تنها زمانی باز می‌کند که
# fail2ban-client نصب و در حال اجرا باشد (jail به نام 3x-ipl).
# ---------------------------------------------------------------
export XUI_ENABLE_FAIL2BAN=true
LOG_FOLDER="/var/log/x-ui"
mkdir -p "$LOG_FOLDER"
touch "$LOG_FOLDER/3xipl.log" "$LOG_FOLDER/3xipl-banned.log"
mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d
rm -f /etc/fail2ban/jail.d/alpine-ssh.conf

cat > /etc/fail2ban/jail.d/3x-ipl.conf << EOF
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=$LOG_FOLDER/3xipl.log
maxretry=1
findtime=32
bantime=30m
EOF

cat > /etc/fail2ban/filter.d/3x-ipl.conf << 'EOF'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

cat > /etc/fail2ban/action.d/3x-ipl.conf << EOF
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -j f2b-<name>

actionstop = <iptables> -D <chain> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
            <iptables> -I f2b-<name> 1 -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> $LOG_FOLDER/3xipl-banned.log

actionunban = <iptables> -D f2b-<name> -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              <iptables> -D f2b-<name> -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> $LOG_FOLDER/3xipl-banned.log

[Init]
name = default
chain = INPUT
exemptports = 22,2053,2054
EOF

echo "▶️  Starting fail2ban..."
fail2ban-client -x start || echo "⚠️  fail2ban start failed (IP Limit may stay locked)"

echo "🔧 Applying panel settings via x-ui CLI..."
./x-ui setting -port 2054 -webBasePath /managepanel/ || true

echo "🔧 Building nginx.conf for fixed port: $NGINX_PORT"
envsubst '${NGINX_PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "▶️  Starting x-ui in background..."
./x-ui &
X_UI_PID=$!

sleep 2

# ---------------------------------------------------------------
# لینک ساب روی دامنه پنل — بدون پورت داخلی 2096
# در پس‌زمینه اجرا می‌شود و داخل subshell با set +e ایزوله شده،
# پس حتی اگر دیتابیس دیر بیاید یا خطا بدهد، nginx و پنل
# هرگز متوقف نمی‌شوند. بعد از هر ریست هم دوباره اعمال می‌شود.
# ---------------------------------------------------------------
(
  set +e
  DB="/etc/x-ui/x-ui.db"
  SUB_URI="https://gucciyt.ccwu.cc/sub/"
  JSON_URI="https://gucciyt.ccwu.cc/json/"
  i=0
  while [ $i -lt 60 ]; do
    if [ -f "$DB" ] && sqlite3 "$DB" "SELECT 1 FROM settings LIMIT 1;" >/dev/null 2>&1; then
      sqlite3 "$DB" "INSERT INTO settings (key,value) VALUES ('subURI','$SUB_URI') ON CONFLICT(key) DO UPDATE SET value='$SUB_URI';" >/dev/null 2>&1
      sqlite3 "$DB" "INSERT INTO settings (key,value) VALUES ('subJsonURI','$JSON_URI') ON CONFLICT(key) DO UPDATE SET value='$JSON_URI';" >/dev/null 2>&1
      echo "subURI applied: $SUB_URI"
      break
    fi
    i=$((i+1))
    sleep 2
  done
) >/dev/null 2>&1 &

echo "▶️  Starting nginx in foreground on port $NGINX_PORT..."
nginx -t
exec nginx -g "daemon off;"
