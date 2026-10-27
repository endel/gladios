# Debian 12's nginx with its njs module (0.7.9, the oldest gladios supports), gladios installed by
# install.sh, test/e2e/site.conf in front of a static app. Build from the repo root:
#   docker build -f test/e2e/Dockerfile .
FROM debian:12
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends nginx libnginx-mod-http-js njs fail2ban python3 curl openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY install.sh /gladios/install.sh
COPY njs /gladios/njs
COPY public /gladios/public
COPY nginx /gladios/nginx
COPY bin /gladios/bin
COPY fail2ban /gladios/fail2ban
COPY cron.d /gladios/cron.d
COPY test/unit.js test/solve.py /gladios/test/
COPY test/e2e /gladios/test/e2e
ENTRYPOINT ["/gladios/test/e2e/entrypoint.sh"]
