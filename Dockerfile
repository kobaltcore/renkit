FROM openjdk:8-jdk-slim-bullseye
ARG renpy_version
ARG renkit_version=v1.0.0

ENV DEBIAN_FRONTEND=noninteractive

# install dependencies and MEGAcmd
RUN apt-get update && \
    apt-get install -y wget unzip && \
    wget https://mega.nz/linux/MEGAsync/Debian_11/amd64/megacmd_1.4.0-3.1_amd64.deb && \
    apt-get install -y ./megacmd_1.4.0-3.1_amd64.deb && \
    rm megacmd_1.4.0-3.1_amd64.deb && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# install renkit tools
RUN wget https://github.com/kobaltcore/renkit/releases/download/$renkit_version/renkit-linux.zip && \
    unzip renkit-linux.zip -d /usr/local/bin && \
    rm renkit-linux.zip

# install the specified version of Ren'Py
RUN renutil install -v $renpy_version

# build for a specific version of Ren'Py with:
# docker build . --tag renpy:7.4.11 --build-arg renpy_version=7.4.11
