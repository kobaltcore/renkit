# build for a specific version of Ren'Py with:
# docker build . --tag renpy:8.2.0 --build-arg renpy_version=8.2.0
# to run commands:
# docker run --rm -it --volume /local/project/path:/project renpy:8.2.0 renutil launch 8.2.0 -d -- "/project compile"

FROM ubuntu:22.04
ARG renpy_version=8.2.0
ARG renkit_version=v4.0.1

ENV DEBIAN_FRONTEND=noninteractive

# install java
ENV JAVA_HOME=/opt/java/openjdk
COPY --from=eclipse-temurin:21-jdk $JAVA_HOME $JAVA_HOME
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# install dependencies
RUN apt-get update && \
    apt-get install -y curl wget xz-utils libgl1 && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV PATH="/root/.cargo/bin:${PATH}"

# install renkit
RUN curl --proto '=https' --tlsv1.2 -LsSf https://github.com/kobaltcore/renkit/releases/download/$renkit_version/renkit-installer.sh | sh

# install the specified version of Ren'Py
RUN $HOME/.cargo/bin/renutil install $renpy_version

# default entrypoint so people can dispatch to any of renkit's tools
CMD [ "/bin/bash", "-c"]
