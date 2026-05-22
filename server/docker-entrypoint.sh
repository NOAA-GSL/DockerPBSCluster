#!/bin/bash

set -e
set -o pipefail

export PATH=/opt/pbs/bin:/opt/pbs/sbin:$PATH

dump_diagnostics() {
    echo "================== PBS SERVER FAILURE DIAGNOSTICS =================="
    echo "--- uname / os-release ---"
    uname -a || true
    cat /etc/os-release 2>/dev/null || true
    echo "--- /etc/pbs.conf ---"
    sudo cat /etc/pbs.conf 2>&1 || true
    echo "--- processes ---"
    sudo ps -efw 2>&1 || true
    echo "--- postgres / pbs_ processes ---"
    sudo pgrep -af 'postgres|pbs_' 2>&1 || echo "(none)"
    echo "--- listening sockets ---"
    sudo ss -lntp 2>&1 || sudo netstat -lntp 2>&1 || true
    echo "--- /var/run/postgresql ---"
    sudo ls -la /var/run/postgresql/ 2>&1 || echo "(missing)"
    echo "--- /run ---"
    sudo ls -la /run/ 2>&1 || true
    echo "--- /var/spool/pbs ---"
    sudo ls -la /var/spool/pbs/ 2>&1 || true
    echo "--- /var/spool/pbs/server_priv ---"
    sudo ls -la /var/spool/pbs/server_priv/ 2>&1 || true
    echo "--- /var/spool/pbs/server_priv/db_* ---"
    sudo sh -c 'for f in /var/spool/pbs/server_priv/db_*; do echo "=== $f ==="; cat "$f" 2>&1 || true; done' || true
    echo "--- /var/spool/pbs/datastore ---"
    sudo ls -la /var/spool/pbs/datastore/ 2>&1 || echo "(missing)"
    echo "--- PBS data service log (pg_log) ---"
    sudo sh -c 'tail -n 200 /var/spool/pbs/datastore/pg_log/* 2>&1' || echo "(no pg_log)"
    echo "--- PBS server_logs ---"
    sudo sh -c 'tail -n 200 /var/spool/pbs/server_logs/* 2>&1' || echo "(no server_logs)"
    echo "--- PBS comm_logs ---"
    sudo sh -c 'tail -n 100 /var/spool/pbs/comm_logs/* 2>&1' || echo "(no comm_logs)"
    echo "--- PBS sched_logs ---"
    sudo sh -c 'tail -n 100 /var/spool/pbs/sched_logs/* 2>&1' || echo "(no sched_logs)"
    echo "===================================================================="
}

on_error() {
    rc=$?
    echo "ERROR: docker-entrypoint.sh failed (exit code $rc) at line ${1:-?}"
    dump_diagnostics
    echo "Keeping container alive for inspection (docker exec / tmate)."
    exec tail -f /dev/null
}
trap 'on_error $LINENO' ERR

# Ensure the PostgreSQL runtime socket directory exists with the right perms.
# In Docker there is no systemd-tmpfiles to create /run/postgresql, and PBS's
# data service uses /var/run/postgresql as its unix socket dir. Without this,
# `pg_db_utility install_db` can fail with:
#   createdb: connection to server on socket "/var/run/postgresql/.s.PGSQL.15007"
#   failed: No such file or directory
sudo install -d -o postgres -g postgres -m 2775 /var/run/postgresql

# Initialize the PBS PostgreSQL datastore.
# install_db has a known race condition: pbs_dataservice considers postgres
# "started" as soon as the process is up, but createdb can hit "the database
# system is starting up" if it connects before postgres finishes WAL recovery.
# We retry the whole install_db invocation; each retry runs initdb from
# scratch, so the race window is re-rolled. If we still fail after a few
# attempts, we continue anyway: `pbs_server -t create` is able to bootstrap
# the datastore itself and is the real source of truth for startup success.
#
# Calling install_db inside an `if` (or via `|| true`) is essential: the
# `trap ... ERR` above fires on *any* simple-command non-zero exit, even
# under `set +e`. Only the conditional context suppresses it.
echo "Initializing PBS datastore (pbs_db_utility install_db)..."
install_db_rc=1
for attempt in 1 2 3 4 5; do
    # Make sure no stale data-service state from a failed previous attempt is
    # left around: pbs_dataservice's "cleanup" doesn't always tear down the
    # pbs_ds_monitor process, which can confuse the next attempt.
    # Match by process name only (not full cmdline) so pkill doesn't match
    # its own sudo wrapper.
    sudo pkill -9 -x pbs_ds_monitor 2>/dev/null || true
    sudo pkill -9 -x postgres 2>/dev/null || true
    sudo rm -rf /var/spool/pbs/datastore 2>/dev/null || true

    # Use `|| install_db_rc=$?` rather than `if cmd; then ... fi`: after an
    # `if`, $? is the exit status of the if statement itself (0 when the
    # then-branch didn't run), so we'd report the wrong rc on failure.
    install_db_rc=0
    sudo /opt/pbs/libexec/pbs_db_utility install_db || install_db_rc=$?
    if [ "$install_db_rc" -eq 0 ]; then
        echo "install_db succeeded on attempt $attempt."
        break
    fi
    echo "install_db attempt $attempt failed (rc=$install_db_rc); retrying in 10s..."
    sleep 10
done
if [ "$install_db_rc" -ne 0 ]; then
    echo "WARN: install_db failed after 5 attempts; will rely on pbs_server -t create to bootstrap."
fi

# Start pbs_comm first (pbs_server requires it)
echo "Starting pbs_comm..."
sudo /opt/pbs/sbin/pbs_comm

# Start PBS server with -t create (creates schema if needed, then daemonizes)
echo "Starting pbs_server -t create..."
sudo /opt/pbs/sbin/pbs_server -t create

# Verify pbs_server is actually alive and responding. This is the real gate:
# if pbs_server can't talk to its datastore, qstat will keep failing.
echo "Waiting for pbs_server to accept requests..."
for i in $(seq 1 60); do
    if sudo /opt/pbs/bin/qstat -Bf >/dev/null 2>&1; then
        echo "pbs_server is responding (after ${i}s)."
        break
    fi
    sleep 1
    if [ "$i" -eq 60 ]; then
        echo "ERROR: pbs_server did not become responsive within 60s."
        sudo pgrep -af pbs_server || echo "(no pbs_server process running)"
        exit 1
    fi
done

# Start scheduler
echo "Starting pbs_sched..."
sudo /opt/pbs/sbin/pbs_sched

# Configure server. These are idempotent-on-restart; some commands intentionally
# error if a queue/node/hook already exists. The ERR trap fires on *any*
# non-zero exit (not gated by `set -e`), so each command must be `|| true`'d
# rather than relying on set +e.
sudo /opt/pbs/bin/qmgr -c "create queue workq queue_type=execution" 2>/dev/null || true
sudo /opt/pbs/bin/qmgr -c "set queue workq enabled = True" || true
sudo /opt/pbs/bin/qmgr -c "set queue workq started = True" || true
sudo /opt/pbs/bin/qmgr -c "set server default_queue = workq" || true
sudo /opt/pbs/bin/qmgr -c "set server scheduling = True" || true
sudo /opt/pbs/bin/qmgr -c "set server flatuid = True" || true
sudo /opt/pbs/bin/qmgr -c "set server job_history_enable = True" || true

sudo /opt/pbs/bin/qmgr -c "create node pbsnode1" 2>/dev/null || true
sudo /opt/pbs/bin/qmgr -c "create node pbsnode2" 2>/dev/null || true
sudo /opt/pbs/bin/qmgr -c "create node pbsnode3" 2>/dev/null || true

# Create a queuejob hook that defaults output/error paths to the submission
# directory (PBS_O_WORKDIR) instead of $HOME on the submission host.
# PBS treats a bare directory path (no hostname) as a local path, so pbs_mom
# on the compute node writes directly to the shared /home/admin volume.
cat > /tmp/default_output_dir.py << 'PYEOF'
import pbs
e = pbs.event()
j = e.job
try:
    workdir = str(j.Variable_List['PBS_O_WORKDIR'])
    if workdir:
        j.Output_Path = workdir
        j.Error_Path = workdir
except Exception as ex:
    pbs.logmsg(pbs.LOG_DEBUG, 'default_output_dir: ' + str(ex))
e.accept()
PYEOF
sudo /opt/pbs/bin/qmgr -c "create hook default_output_dir" 2>/dev/null || true
sudo /opt/pbs/bin/qmgr -c "set hook default_output_dir event = queuejob" || true
sudo /opt/pbs/bin/qmgr -c "import hook default_output_dir application/x-python default /tmp/default_output_dir.py" || true

# Regenerate SSH host keys (keys are not baked into the image)
sudo ssh-keygen -A

# Start SSH
sudo service ssh start

# Marker file used by the docker-compose healthcheck so `up --wait` blocks
# until the server is actually ready (not just until the container started).
sudo touch /tmp/pbs-server-ready

echo "PBS server startup completed successfully."

tail -f /dev/null
