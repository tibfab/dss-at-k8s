# Docker image to host a DSS installation mounted on a persistent volume
# Additional installation steps needed
# - DSS dependencies, autostart, UIF activation, conda path
# - DSS user
# - K8S config
FROM ubuntu:18.04

RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    sudo \
    curl \
    wget \
    gawk \
    net-tools \
    iputils-ping \
    zip \
    vim \
    locales \
    htop \
    git \
    nano \
    openjdk-8-jdk \
 && locale-gen en_US.UTF-8 \
 && update-alternatives --set java /usr/lib/jvm/java-8-openjdk-amd64/jre/bin/java

# create passwordless sudo DSS user
ARG DSS_USER='ubuntu'

RUN useradd -s /bin/bash -d /home/${DSS_USER} -m -G sudo -u 1000 ${DSS_USER} \
 && printf "${DSS_USER}    ALL=(ALL) NOPASSWD:ALL\n" >> /etc/sudoers \
 && printf "%s\n" "" \
    "export DOCKER_HOST=tcp://localhost:2375" >> /home/${DSS_USER}/.bashrc

USER ${DSS_USER}
ENV USER ${DSS_USER}
WORKDIR /home/${DSS_USER}

ARG DOCKER_CLI_PKG='docker-ce-cli_19.03.8~3-0~ubuntu-bionic_amd64.deb'

RUN wget https://download.docker.com/linux/ubuntu/dists/bionic/pool/stable/amd64/docker-ce-cli_19.03.8~3-0~ubuntu-bionic_amd64.deb \
 && sudo dpkg -i ${DOCKER_CLI_PKG} \
 && mkdir .docker \
 && printf "%s\n" \
    "{" \
    "   \"proxies\": {" \
    "            \"default\": {" \
    "                     \"noProxy\": \"169.254.169.254\"" \
    "            }" \
    "   }" \
    "}" > .docker/config.json \
 && rm ${DOCKER_CLI_PKG} \
 && curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl" \
 && chmod +x ./kubectl \
 && sudo mv ./kubectl /usr/local/bin/kubectl

