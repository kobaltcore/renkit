# build for a specific version of Ren'Py with:
# docker build . --tag renpy:8.0.3 --build-arg renpy_version=8.0.3
# to run commands:
# docker run --rm -it --volume /local/project/path:/project renpy:8.0.3 'renutil launch -v 8.0.3 --headless -d -a "/project compile"'

FROM --platform=linux/x86_64 openjdk:8-jdk-slim-bullseye
ARG renpy_version=8.0.3
ARG renkit_version=v3.2.0

ENV DEBIAN_FRONTEND=noninteractive

# install dependencies
RUN apt-get update && \
    apt-get install -y curl wget libgl1 && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# install renkit tools
RUN wget -qO- https://github.com/kobaltcore/renkit/releases/download/$renkit_version/renkit-linux-amd64.tar.gz | tar xz -C /usr/local/bin

# install the specified version of Ren'Py
RUN renutil install -v $renpy_version

# default entrypoint so people can dispatch to any of renkit's tools
ENTRYPOINT ["sh", "-c"]
