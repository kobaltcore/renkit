FROM openjdk:8-jdk-slim-bullseye
ARG renpy_version
ARG renkit_version=v1.2.3

ENV DEBIAN_FRONTEND=noninteractive

# install dependencies
RUN apt-get update && \
    apt-get install -y wget unzip && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# install renkit tools
RUN wget https://github.com/kobaltcore/renkit/releases/download/$renkit_version/renkit-linux-amd64.zip && \
    unzip renkit-linux-amd64.zip -d /usr/local/bin && \
    rm renkit-linux-amd64.zip

# install the specified version of Ren'Py
RUN renutil install -v $renpy_version

# build for a specific version of Ren'Py with:
# docker build . --tag renpy:8.0.0 --build-arg renpy_version=8.0.0
