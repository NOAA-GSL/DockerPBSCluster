#!/bin/bash

export PATH=/opt/pbs/bin:/opt/pbs/sbin:$PATH


# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    pg_isready -U pbsdata -h /var/run/postgresql -p 15007 && break
    sleep 1
done

# Initialize the PBS PostgreSQL datastore
echo "Initializing PBS datastore..."
sudo /opt/pbs/libexec/pbs_db_utility install_db

# Start pbs_comm first (pbs_server requires it)
sudo /opt/pbs/sbin/pbs_comm

# Start PBS server with -t create (creates schema if needed, then runs as daemon)
echo "Starting PBS server..."
sudo /opt/pbs/sbin/pbs_server -t create

# Start scheduler
sudo /opt/pbs/sbin/pbs_sched

# Wait for PBS server to be ready
echo "Waiting for PBS server..."
for i in $(seq 1 30); do
    sudo /opt/pbs/bin/qstat -Bf > /dev/null 2>&1 && break
    sleep 1
done

# Configure server (|| true so restarts don't fail on "already exists")
sudo /opt/pbs/bin/qmgr -c "create queue workq queue_type=execution" 2>/dev/null || true
sudo /opt/pbs/bin/qmgr -c "set queue workq enabled = True"
sudo /opt/pbs/bin/qmgr -c "set queue workq started = True"
sudo /opt/pbs/bin/qmgr -c "set server default_queue = workq"
sudo /opt/pbs/bin/qmgr -c "set server scheduling = True"
sudo /opt/pbs/bin/qmgr -c "set server flatuid = True"
sudo /opt/pbs/bin/qmgr -c "set server job_history_enable = True"

# Register compute nodes
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
sudo /opt/pbs/bin/qmgr -c "set hook default_output_dir event = queuejob"
sudo /opt/pbs/bin/qmgr -c "import hook default_output_dir application/x-python default /tmp/default_output_dir.py"

# Regenerate SSH host keys (keys are not baked into the image)
sudo ssh-keygen -A

# Start SSH
sudo service ssh start

tail -f /dev/null
