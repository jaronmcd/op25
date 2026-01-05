# Home Assistant Add-on: OP25 (GNU Radio) P25 Scanner
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:bookworm
FROM ${BUILD_FROM}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# Runtime + build deps
# NOTE: We build OP25 from source against Debian's packaged GNU Radio.
# -----------------------------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        bash \
        curl \
        jq \
        git \
        \
        # Python
        python3 \
        python3-dev \
        python3-distutils \
        python3-numpy \
        python3-requests \
        python3-waitress \
        \
        # Build toolchain
        build-essential \
        cmake \
        pkg-config \
        \
        # GNU Radio + SDR sources
        gnuradio \
        gnuradio-dev \
        gr-osmosdr \
        librtlsdr0 \
        librtlsdr-dev \
        libuhd-dev \
        libhackrf-dev \
        soapysdr-tools \
        \
        # OP25 build deps
        libcppunit-dev \
        libspdlog-dev \
        libfmt-dev \
        libsndfile1-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/op25

# Copy everything (including op25/ source) into the image
COPY . /opt/op25

# Build & install OP25
RUN mkdir -p /opt/op25/build \
    && cd /opt/op25/build \
    && cmake -DCMAKE_BUILD_TYPE=Release .. \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig \
    && echo "/usr/bin/python3" > /opt/op25/op25/gr-op25_repeater/apps/op25_python

# Add-on entrypoint
COPY run.sh /run.sh
RUN chmod a+x /run.sh

ENV PYTHONUNBUFFERED=1
ENV TERM=xterm-256color

CMD ["/run.sh"]
