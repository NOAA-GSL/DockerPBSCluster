ARG UBUNTU_BASE=ubuntu:26.04
FROM ${UBUNTU_BASE}

ARG OPENPBS_VERSION=23.06.06
ARG DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update -y && apt-get install -y \
    gcc \
    g++ \
    make \
    autoconf \
    automake \
    libtool \
    git \
    wget \
    vim \
    sudo \
    openssh-server \
    python3 \
    python3-dev \
    libpq-dev \
    libical-dev \
    libedit-dev \
    libhwloc-dev \
    libssl-dev \
    swig \
    pkg-config \
    expat \
    libexpat1-dev \
    tcl-dev \
    tk-dev \
    libxt-dev \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_* \
 && rm -f /etc/ssl/private/ssl-cert-snakeoil.key \
 && rm -f /etc/ssl/certs/ssl-cert-snakeoil.pem \
 && rm -f /usr/bin/pebble

# Create stub eval.h for Python 3.13+ compatibility (header removed but API still present)
RUN python3 -c "import sysconfig; open(sysconfig.get_path('include')+'/eval.h','w').write('#pragma once\n')"

# Clone, configure, build and install OpenPBS in a single layer so that no
# intermediate artefacts (including test keys in ci/) are committed to the image.
RUN git clone --branch v${OPENPBS_VERSION} --depth 1 https://github.com/openpbs/openpbs.git /tmp/openpbs \
 && cd /tmp/openpbs \
 && ./autogen.sh \
 && ./configure --prefix=/opt/pbs CFLAGS="-Wno-incompatible-pointer-types -std=gnu11" \
 && make -j$(nproc) \
 && make install \
 && /opt/pbs/libexec/pbs_postinstall \
 && rm -rf /tmp/openpbs

# Configure PBS as client only (no daemons)
RUN echo "PBS_EXEC=/opt/pbs"           >  /etc/pbs.conf \
 && echo "PBS_HOME=/var/spool/pbs"     >> /etc/pbs.conf \
 && echo "PBS_SERVER=pbsserver"        >> /etc/pbs.conf \
 && echo "PBS_START_SERVER=0"          >> /etc/pbs.conf \
 && echo "PBS_START_SCHED=0"           >> /etc/pbs.conf \
 && echo "PBS_START_COMM=0"            >> /etc/pbs.conf \
 && echo "PBS_START_MOM=0"             >> /etc/pbs.conf

# Create admin user
RUN useradd -m admin -s /usr/bin/bash -d /home/admin \
 && echo "admin:admin" | chpasswd \
 && adduser admin sudo \
 && echo "admin     ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Configure SSH
RUN mkdir -p /var/run/sshd \
 && sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd \
 && chmod -x /etc/update-motd.d/* \
 && rm -f /etc/legal

# Add PBS binaries to system PATH
RUN echo 'export PATH=/opt/pbs/bin:/opt/pbs/sbin:$PATH' >> /etc/profile.d/pbs.sh \
 && chmod +x /etc/profile.d/pbs.sh

# Set permissions for PBS directories
RUN chmod 4755 /opt/pbs/sbin/pbs_iff \
 && chmod 4755 /opt/pbs/sbin/pbs_rcp

COPY docker-entrypoint.sh /opt/pbs/docker-entrypoint.sh
RUN chmod +x /opt/pbs/docker-entrypoint.sh

COPY ssh /home/admin/.ssh
RUN chown -R admin:admin /home/admin/.ssh \
 && chmod -R 700 /home/admin/.ssh

WORKDIR /home/admin

EXPOSE 22

ENV USER=admin
ENV SHELL=bash

ENTRYPOINT ["/opt/pbs/docker-entrypoint.sh"]
