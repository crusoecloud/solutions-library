#!/bin/bash
set -euo pipefail

echo "==> Expanding /dev/shm for NCCL multi-GPU shared memory..."
mount -o remount,size=16G /dev/shm

echo "==> Setting memlock to unlimited..."
sudo bash -c "echo -e \"* soft memlock unlimited\n* hard memlock unlimited\" >> /etc/security/limits.conf"

echo "==> Installing openmpi..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openmpi-bin openmpi-common libopenmpi-dev

echo "==> Configuring SSH..."
mkdir -p /root/.ssh /run/sshd
cp /mnt/sshd-config/sshd_config /etc/ssh/sshd_config
cp /mnt/ssh-keys/authorized_keys /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

echo "==> Creating clouduser account..."
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
# Set /root permissions so that other users can run rccl test binaries
chmod 755 /root

# generate a local keypair for clouduser
if [ ! -f /home/clouduser/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -N "" -f /home/clouduser/.ssh/id_ed25519 -q
  cat /home/clouduser/.ssh/id_ed25519.pub >> /home/clouduser/.ssh/authorized_keys
  chown clouduser:clouduser /home/clouduser/.ssh/id_ed25519 && chmod 400 /home/clouduser/.ssh/id_ed25519
fi

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
