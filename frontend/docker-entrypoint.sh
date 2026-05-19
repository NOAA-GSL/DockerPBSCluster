#!/bin/bash

export PATH=/opt/pbs/bin:/opt/pbs/sbin:$PATH

# Regenerate SSH host keys (keys are not baked into the image)
sudo ssh-keygen -A

# Start SSH
sudo service ssh start

# Generate SSH keys for admin user
ssh-keygen -t rsa -f /home/admin/.ssh/id_rsa -N ""
cp /home/admin/.ssh/id_rsa.pub /home/admin/.ssh/authorized_keys

tail -f /dev/null
