#!/bin/bash
set -euo pipefail

echo "==> Expanding /dev/shm for NCCL multi-GPU shared memory..."
mount -o remount,size=16G /dev/shm

echo "==> Installing openssh-server if not present..."
if ! command -v sshd &>/dev/null; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server
fi

echo "==> Configuring SSH..."
mkdir -p /root/.ssh /run/sshd
cp /mnt/sshd-config/sshd_config /etc/ssh/sshd_config
cp /mnt/ssh-keys/authorized_keys /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

#echo "==> Generating SSH host keys..."
#ssh-keygen -A

echo "==> Creating clouduser account..."
# /etc/passwd is ephemeral, so recreate the account on every pod start.
# /home/clouduser lives on the PVC and persists across restarts.
useradd --uid 1010 --no-create-home --home-dir /home/clouduser --shell /bin/bash clouduser
mkdir -p /home/clouduser/.ssh
chown clouduser:clouduser /home/clouduser
chmod 755 /home/clouduser
# Seed authorized_keys only on first boot; on restart the file already exists on the PVC.
if [ ! -f /home/clouduser/.ssh/authorized_keys ]; then
  cp /mnt/ssh-keys/authorized_keys /home/clouduser/.ssh/authorized_keys
  chown clouduser:clouduser /home/clouduser/.ssh/authorized_keys
  chmod 600 /home/clouduser/.ssh/authorized_keys
fi
chown clouduser:clouduser /home/clouduser/.ssh
chmod 700 /home/clouduser/.ssh

echo "==> Adding clouduser to GPU device groups..."
groupadd -g 44 video 2>/dev/null || true
groupadd -g 109 render 2>/dev/null || true
groupadd -g 992 kfd 2>/dev/null || true
usermod -aG video,render,kfd clouduser

echo "==> Granting clouduser passwordless sudo..."
echo 'clouduser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/clouduser
chmod 440 /etc/sudoers.d/clouduser

echo "==> Starting sshd..."
/usr/sbin/sshd

echo "==> Pod is ready. Staying alive..."
# Keep the container running. sshd runs as a daemon above.
# If sshd exits unexpectedly, restart it in the loop so SSH remains accessible.
while true; do
  if ! pgrep -x sshd &>/dev/null; then
    echo "==> sshd not running, restarting..."
    /usr/sbin/sshd
  fi
  sleep 30
done
