# Debian 12's nginx and php-fpm, gladios installed by install.sh, test/e2e/site.conf in front of a
# static app. Build from the repo root: docker build -f test/e2e/Dockerfile .
FROM debian:12
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends nginx php-fpm php-cli curl openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY install.sh /gladios/install.sh
COPY src /gladios/src
COPY public /gladios/public
COPY nginx /gladios/nginx
COPY test/e2e /gladios/test/e2e
ENTRYPOINT ["/gladios/test/e2e/entrypoint.sh"]
