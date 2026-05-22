#!/bin/bash

set -e
set -o pipefail

export PATH=/opt/pbs/bin:/opt/pbs/sbin:$PATH

dump_diagnostics() {
    echo "================== PBS SERVER FAILURE DIAGNOSTICS =================="
    echo "--- uname / lsb-release ---"
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
    echo "--- /var/spool/pbs ---"
    sudo ls -la /var/spool/pbs/ 2>&1 || true
    echo "--- /var/spool/pbs/server_priv ---"
    sudo ls -la /var/spool/pbs/server_priv/ 2>&1 || true
    echo "--- /var/spool/pbs/server_priv/db_* ---"
    sudo sh -c 'for f in /var/spool/pbs/server_priv/db_*; do echo "=== $f ==="; cat "$f" 2>&1 || true; done' || true
    echo "--- /var/spool/pbs/datastore ---"
    sudo ls -la /var/spool/pbs/datastore/ 2>&1 || true
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
    # Don't exit -- keep PID 1 alive so the container doesn't restart and lose state.
    exec tail -f /dev/null
}
trap 'on_error $LINENO' ERR

# Initialize the PBS PostgreSQL datastore.
# This is responsible for initdb, creating the pbsdata role+db, applying the
# schema, and starting the PBS data service (postgres on port 15007).
echo "Initializing PBS datastore (pbs_db_utility install_db)..."
sudo /opt/pbs/libexec/pbs_db_utility install_db
echo "install_db returned $?"

# Verify the PBS data service is actually accepting connections.
echo "Waiting for PBS data service on port 15007..."
for i in $(seq 1 60); do
    if pg_isready -U pbsdata -h /var/run/postgresql -p 15007 >/dev/null 2>&1; then
        echo "PBS data service is ready (after ${i}s)."
        break
    fi
    sleep 1
    if [ "$i" -eq 60 ]; then
        echo "ERROR: PBS data service did not come up within 60s after install_db."
        exit 1
    fi
done

# Start pbs_comm first (pbs_server requires it)
echo "Starting pbs_comm..."
sudo /opt/pbs/sbin/pbs_comm

# Start PBS server with -t create (creates schema if needed, then daemonizes)
echo "Starting pbs_server -t create..."
sudo /opt/pbs/sbin/pbs_server -t create

# Verify pbs_server is actually alive and responding
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

# Configure server. These are idempotent-on-restart; some commands are
# expected to "fail" (e.g. queue already exists), so don't trip the ERR trap.
set +e
sudo /opt/pbs/bin/qmgr -c "create queue workq queue_type=execution" 2>/dev/null
sudo /opt/pbs/bin/qmgr -c "set queue workq enabled = True"
sudo /opt/pbs/bin/qmgr -c "set queue workq started = True"
sudo /opt/pbs/bin/qmgr -c "set server default_queue = workq"
sudo /opt/pbs/bin/qmgr -c "set server scheduling = True"
sudo /opt/pbs/bin/qmgr -c "set server flatuid = True"
sudo /opt/pbs/bin/qmgr -c "set server job_history_enable = True"

sudo /opt/pbs/bin/qmgr -c "create node pbsnode1" 2>/dev/null
sudo /opt/pbs/bin/qmgr -c "create node pbsnode2" 2>/dev/null
sudo /opt/pbs/bin/qmgr -c "create node pbsnode3" 2>/dev/null
set -e

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
set +e
sudo /opt/pbs/bin/qmgr -c "create hook default_output_dir" 2>/dev/null
sudo /opt/pbs/bin/qmgr -c "set hook default_output_dir event = queuejob"
sudo /opt/pbs/bin/qmgr -c "import hook default_output_dir application/x-python default /tmp/default_output_dir.py"
set -e

# Regenerate SSH host keys (keys are not baked into the image)
sudo ssh-keygen -A

# Start SSH
sudo service ssh start

# Marker file used by the docker-compose healthcheck so `up --wait` blocks
# until the server is actually ready (not just until the container started).
sudo touch /tmp/pbs-server-ready

echo "PBS server startup completed successfully."

tail -f /dev/null
