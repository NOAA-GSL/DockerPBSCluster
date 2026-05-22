ARG UBUNTU_BASE=ubuntu:26.04
FROM ${UBUNTU_BASE}

ARG OPENPBS_VERSION=23.06.06
ARG DEBIAN_FRONTEND=noninteractive


# Add the official PGDG repo for the detected Ubuntu codename and always install PostgreSQL 15
RUN apt-get update -y && apt-get install -y wget ca-certificates gnupg lsb-release \
 && install -d /usr/share/keyrings \
 && wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
 && UBUNTU_CODENAME=$(lsb_release -cs) \
 && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] https://apt.postgresql.org/pub/repos/apt $UBUNTU_CODENAME-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
 && rm -rf /var/lib/apt/lists/*

# Install dependencies, always using PostgreSQL 15
RUN apt-get update -y \
 && apt-get install -y \
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
         postgresql-15 \
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
 && rm -f /etc/ssl/certs/ssl-cert-snakeoil.pem

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

# Fix race in pbs_db_utility install_db: the upstream script polls
# `pbs_dataservice status`, which returns success as soon as the postgres
# process exists -- before WAL recovery completes. createdb then hits
# "FATAL: the database system is starting up". Replace that probe with
# pg_isready (returns 0 only when postgres is accepting connections) and
# bump the retry budget from ~12s to ~60s for slower CI runners.
# Fail the build if any anchor changes upstream so we notice early.
RUN grep -q '^	tries=5$' /opt/pbs/libexec/pbs_db_utility \
 && grep -q '\${server_ctl} status > /dev/null 2>&1' /opt/pbs/libexec/pbs_db_utility \
 && sed -i \
        -e '0,/^	tries=5$/{s||	tries=30|}' \
        -e 's|\${server_ctl} status > /dev/null 2>&1|\${bin_dir}/pg_isready -h /var/run/postgresql -p \${port} -q > /dev/null 2>\&1|' \
        /opt/pbs/libexec/pbs_db_utility \
 && grep -q 'pg_isready -h /var/run/postgresql -p \${port} -q > /dev/null 2>&1' /opt/pbs/libexec/pbs_db_utility \
 && grep -q '^	tries=30$' /opt/pbs/libexec/pbs_db_utility

# Create pbsdata system user required by PBS dataservice (normally done by package manager)
RUN useradd -r -m -d /var/lib/pbsdata -s /bin/sh -G postgres pbsdata

# Fix the db_user file: pbs_postinstall writes "postgres" but we use pbsdata
RUN echo -n pbsdata > /var/spool/pbs/server_priv/db_user

# Symlink PostgreSQL 15 server binaries into /usr/bin so pbs_db_utility can
# find them via PATH under sudo.
RUN for bin in initdb pg_ctl createdb psql pg_config; do \
            ln -sf /usr/lib/postgresql/15/bin/${bin} /usr/bin/${bin}; \
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

WORKDIR /home/admin

EXPOSE 22 15001 15003 17001

ENTRYPOINT ["/opt/pbs/docker-entrypoint.sh"]
