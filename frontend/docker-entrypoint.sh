#!/bin/bash

export PATH=/opt/pbs/bin:/opt/pbs/sbin:$PATH


# Regenerate SSH host keys only if missing (prevents SSH warnings on restart)
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    sudo ssh-keygen -A
fi

# Start SSH
sudo service ssh start

# Generate SSH key and set up shared authorized_keys
if [ ! -f /home/admin/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -f /home/admin/.ssh/id_rsa -N ""
    cp /home/admin/.ssh/id_rsa.pub /home/admin/.ssh/authorized_keys
    chown -R admin:admin /home/admin/.ssh
    chmod 700 /home/admin/.ssh
    chmod 600 /home/admin/.ssh/authorized_keys
fi

touch /tmp/ssh-ready

tail -f /dev/null
