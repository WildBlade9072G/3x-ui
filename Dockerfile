FROM alpine:3.19

RUN apk add --no-cache \
    curl \
    bash \
    ca-certificates \
    socat \
    tzdata \
    sqlite \
    nginx \
    gettext \
    fail2ban \
    && ln -sf /usr/share/zoneinfo/Asia/Tehran /etc/localtime

# دانلود و نصب 3x-ui
RUN curl -L https://github.com/mhsanaei/3x-ui/releases/download/v3.5.0/x-ui-linux-amd64.tar.gz -o /tmp/x-ui.tar.gz \
    && tar -xzf /tmp/x-ui.tar.gz -C /usr/local/ \
    && rm /tmp/x-ui.tar.gz \
    && chmod +x /usr/local/x-ui/x-ui

RUN mkdir -p /etc/x-ui /var/log/x-ui

# ---------------------------------------------------------------
# دیتابیس پنل در /etc/x-ui است. بدون VOLUME هر ری‌دیپلوی آن را
# پاک می‌کند و اینباند/کلاینت/تنظیمات از بین می‌رود.
# با VOLUME می‌توان در Railway یک دیسک دائمی به این مسیر وصل کرد.
# ---------------------------------------------------------------
VOLUME ["/etc/x-ui"]

COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY subtheme/ /usr/local/x-ui/subtheme/
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Railway پورت رو از طریق متغیر $PORT تزریق می‌کند
CMD ["/start.sh"]
