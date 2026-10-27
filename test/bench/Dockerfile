# The load generator for test/bench/run.sh: oha, plus curl and python3 to solve a check first.
FROM debian:12
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends curl python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ADD --chmod=0755 https://github.com/hatoo/oha/releases/download/v1.14.0/oha-linux-${TARGETARCH} /usr/local/bin/oha
COPY test/solve.py /solve.py
