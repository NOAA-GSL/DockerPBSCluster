#!/bin/bash

export PATH=/opt/pbs/bin:/opt/pbs/sbin:$PATH

# Tell pbs_mom to use local cp instead of network delivery for /home/admin.
# Since /home/admin is a shared Docker volume, this prevents jobs getting stuck
# in E state when pbs_mom cannot reach the submission host over the network.
echo '$usecp *:/home/admin /home/admin' | sudo tee -a /var/spool/pbs/mom_priv/config > /dev/null

# Start pbs_mom
sudo /opt/pbs/sbin/pbs_mom


# Regenerate SSH host keys only if missing (prevents SSH warnings on restart)
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
	sudo ssh-keygen -A
fi

# Start SSH
sudo service ssh start

tail -f /dev/null
