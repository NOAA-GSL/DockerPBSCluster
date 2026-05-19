ARG UBUNTU_BASE=ubuntu:26.04@sha256:f3d28607ddd78734bb7f71f117f3c6706c666b8b76cbff7c9ff6e5718d46ff64
FROM ${UBUNTU_BASE}

ARG OPENPBS_VERSION=23.06.06
ARG DEBIAN_FRONTEND=noninteractive

# Pin PostgreSQL 16: ubuntu 26.04 ships pg18, which OpenPBS 23.x does not
# support.  Add the official PGDG repo so we can install a compatible version.
RUN apt-get update -y && apt-get install -y wget ca-certificates gnupg \
 && install -d /usr/share/keyrings \
 && wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] https://apt.postgresql.org/pub/repos/apt resolute-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list \
 && rm -rf /var/lib/apt/lists/*

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
    postgresql-16 \
    postgresql-16-contrib \
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
 && rm -f /etc/ssh/ssh_host_*

# Create stub eval.h for Python 3.13+ compatibility (header removed but API still present)
RUN python3 -c "import sysconfig; open(sysconfig.get_path('include')+'/eval.h','w').write('#pragma once\n')"

# Clone OpenPBS source
RUN git clone --branch v${OPENPBS_VERSION} --depth 1 https://github.com/openpbs/openpbs.git /tmp/openpbs

# Configure OpenPBS
RUN cd /tmp/openpbs \
 && ./autogen.sh \
 && ./configure --prefix=/opt/pbs CFLAGS="-Wno-incompatible-pointer-types -std=gnu11"

# Build and install OpenPBS
RUN cd /tmp/openpbs \
 && make -j$(nproc) \
 && make install \
 && /opt/pbs/libexec/pbs_postinstall \
 && rm -rf /tmp/openpbs

# Create pbsdata system user required by PBS dataservice (normally done by package manager)
RUN useradd -r -m -d /var/lib/pbsdata -s /bin/sh -G postgres pbsdata

# Fix the db_user file: pbs_postinstall writes "postgres" but we use pbsdata
RUN echo -n pbsdata > /var/spool/pbs/server_priv/db_user

# Symlink PostgreSQL 16 server binaries into /usr/bin so pbs_db_utility can
# find them via PATH under sudo.  Hardcode the pg16 path so this is not
# affected by whichever pg_config libpq-dev exposes.
RUN for bin in initdb pg_ctl createdb psql pg_config; do \
        ln -sf /usr/lib/postgresql/16/bin/${bin} /usr/bin/${bin}; \
    done

# Configure PBS as server
RUN echo "PBS_EXEC=/opt/pbs"           >  /etc/pbs.conf \
 && echo "PBS_HOME=/var/spool/pbs"     >> /etc/pbs.conf \
 && echo "PBS_SERVER=pbsserver"        >> /etc/pbs.conf \
 && echo "PBS_START_SERVER=1"          >> /etc/pbs.conf \
 && echo "PBS_START_SCHED=1"           >> /etc/pbs.conf \
 && echo "PBS_START_COMM=1"            >> /etc/pbs.conf \
 && echo "PBS_START_MOM=0"             >> /etc/pbs.conf \
 && echo "PBS_DATA_SERVICE_USER=pbsdata" >> /etc/pbs.conf

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

EXPOSE 22 15001 15003 17001

ENTRYPOINT ["/opt/pbs/docker-entrypoint.sh"]
