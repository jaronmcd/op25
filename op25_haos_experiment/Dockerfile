ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

# Home Assistant add-on labels (recommended when not using HA base images)
LABEL \
  io.hass.type="addon" \
  io.hass.arch="amd64|aarch64" \
  org.opencontainers.image.title="OP25 (MQTT Talkgroup Totals) [Experiment]" \
  org.opencontainers.image.description="OP25 with optional Home Assistant MQTT discovery + daily talkgroup total-time sensors." \
  org.opencontainers.image.licenses="GPL-3.0-or-later"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# Install OP25 build/runtime deps (mirrors op25/install.sh packages + MQTT)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      cmake \
      build-essential \
      pkg-config \
      gnuradio \
      gnuradio-dev \
      gr-osmosdr \
      librtlsdr-dev \
      libuhd-dev \
      libhackrf-dev \
      liborc-dev \
      libsndfile1-dev \
      libspdlog-dev \
      gnuplot-x11 \
      python3 \
      python3-numpy \
      python3-requests \
      python3-waitress \
      python3-paho-mqtt \
      python3-pip \
 && rm -rf /var/lib/apt/lists/*

# Build OP25 from upstream and then overwrite select Python files with our patched versions.
ARG OP25_REPO=https://github.com/boatbod/op25.git
ARG OP25_REF=master

RUN git clone --depth 1 --branch ${OP25_REF} ${OP25_REPO} /opt/op25-src

# Apply our patched files (ensures MQTT talkgroup totals + HA discovery support matches this repo)
COPY patch/ /tmp/op25_patch/
RUN set -eux; \
    cp -f /tmp/op25_patch/trunking.py /opt/op25-src/op25/gr-op25_repeater/apps/trunking.py; \
    cp -f /tmp/op25_patch/mqtt_ha.py  /opt/op25-src/op25/gr-op25_repeater/apps/mqtt_ha.py; \
    cp -f /tmp/op25_patch/rx.py       /opt/op25-src/op25/gr-op25_repeater/apps/rx.py; \
    cp -f /tmp/op25_patch/multi_rx.py /opt/op25-src/op25/gr-op25_repeater/apps/multi_rx.py; \
    echo "/usr/bin/python3" > /opt/op25-src/op25/gr-op25_repeater/apps/op25_python

# Build and install
RUN set -eux; \
    cd /opt/op25-src; \
    rm -rf build; \
    mkdir build; \
    cd build; \
    cmake ..; \
    make -j"$(nproc)"; \
    make install; \
    ldconfig; \
    # Keep the source tree (apps, configs) for runtime use
    mv /opt/op25-src /opt/op25

# Add-on runtime
COPY run.sh /run.sh
COPY run.py /addon/run.py
RUN chmod +x /run.sh

CMD ["/run.sh"]
