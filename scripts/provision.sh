#!/bin/sh -x

lineinfile() {
	if grep -q "$2" "$1"; then
		sed -i 's/'"$2"'/'"$3"'/' "$1"
	else
		echo "$3" >> "$1"
	fi
}

# Print each line.
set -o xtrace

# Set frontend.
export DEBIAN_FRONTEND=noninteractive

# Create wheel group.
groupadd wheel
echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> "/etc/sudoers" 
visudo -cf /etc/sudoers

# Create benbjohnson user with login key.
useradd -m -G wheel -s /bin/bash benbjohnson
mkdir -p /home/benbjohnson/.ssh
chown benbjohnson:benbjohnson /home/benbjohnson/.ssh && chmod 700 /home/benbjohnson/.ssh
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCpezYgoL33WgiS73KUHyvcsW5UZwp2SKV65QH5bdgZKxUDTSJKkzSSI+qPcueg8FLKYtKdZ2HBn+uYXzHabqRpmtw66Us2bJY0iitzG3V1Szb2RXZNPaf/eKWULUx55XaKZCVg8/viifAMGeC+SI6BdUQFD3LXpzGkRWWfKoqpZGD92400ORcmhOBW/a3afA34L3y+Z6O8LQ57RAHQxwKeTyWc/rgHoLvlyx3H3bV4kGAITCHJDSX+OSvyrwsx9yoi2CHiYBCt5K+gZJMV2P99uro4pyQF+6baDUtQJOW7sT2+2HTHNV8xLyutMDY6w8BQZdj/Z5+vRF0RUdBPi10q8xgb0N3fGkdF+c5W83K9+WwjPtQiNAwIGwrXzaQYsEm6ejkrkJQ6ZilX+cvDya0n42XxCooPRxNxCd9Wqq1o3aTR4ophFA8O1Dnei8RJo3mVuuVa7d8tXiVuTH/cYRYWsty8R/ueJ6Ipgwng4WnChG28beIhP3h9xMz4wi7BBRcazIk9nT/o5o/rcAd7TW+XHmyMdg75zKFBlEAKYWpbkyKesTaE5Ck1gYRmPIiXCcrzl7fg5+q25xFSHXFG4G/v3IpRFgK7AAOVwvJdsPP9m79Zj1g8FdZ/Tzr3yijy+++Y/Zh96O+z0+slkt77aj/NHGoa28jwgyP+oD4Qv7WMww== benbjohnson@yahoo.com" > /home/benbjohnson/.ssh/authorized_keys
chown benbjohnson:benbjohnson /home/benbjohnson/.ssh/authorized_keys && chmod 600 /home/benbjohnson/.ssh/authorized_keys

# Create deploy user with login key.
useradd -m -G wheel -s /bin/bash deploy
mkdir -p /home/deploy/.ssh
chown deploy:deploy /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQD0X463ba3Ac5XToVW100A2KeQRJ2pkX75TPxv1weXrTpfZqeAvL5bG9Dn5w5M2ujsp7ATLoSIXxB5e1dk0IzJ93e+3F3XJ1Qw4okV7sqMiim4O19u73CM4LKRj4V5DH0ieqnybVBg3uS8V+R5658vPSYPk2MpQQUTZrLI4YGsg89KH3UUQgQQpJSdCLvgR4yZ/W8knvlV07sgKbGlWDsw5az/aYzknIukRBHGo4oHr6OK5Cm4ozQ6iprkLTM9zuZYRiCDzctq49HM3gYHZAcwQtBVSu+Hv9aH5DDYNfngoNeRTS9exLzMmhrMMPIDO+7hFmaD58p4jnYvC6QzadLUnCM5zPQAtrQ1NusmibcjHkHhpom0bl/8TpmvXgASJN7NRkFctdzaL0By4uRPBqWpiCNE2YxT7gTlmluet7Vk48hCn6RxRWc0EMP4nGXrdvtAxsaHjYrWGoFstZWPeMOF65PdF20TFJoorv4ApsHrvvGPvvvyzyFg9G1Abi5oss/l7vaFbdSPzvjv3VJcGinuuy+bgpwT8M+lkGQfsGgDNrQu81V2T/OangJ8ML3sKrt6yj7qEJ58gOguRzshjD8tnlXOx70V5XMCxhTpXM5yrhPCYtoMnR/04ra5jwNVo/cOXo7wCbNqr05SHqi7PU+PS3NTXdPjSjU6qph9kFSP55Q== deploy@gobeyond.dev" > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys && chmod 600 /home/deploy/.ssh/authorized_keys

# Install and update packages.
apt update && apt upgrade -y
apt install -y ufw sqlite3 unattended-upgrades

# Set periodic upgrade settings.
cat <<EOF > /etc/apt/apt.conf.d/10periodic
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Create GHA user.
useradd -s /sbin/nologin gha
mkdir -p /home/gha
chown gha:gha /home/gha && chmod 700 /home/gha

# Install systemd service.
cat <<EOF > /etc/systemd/system/gha.service
[Unit]
Description=GHA

[Service]
User=gha
Group=gha
Environment=ROLLBAR_TOKEN=
Restart=on-failure
ExecStart=/usr/local/bin/gha -ingest-rate 10 /var/lib/gha/db

[Install]
WantedBy=multi-user.target
EOF

chown root:root /etc/systemd/system/gha.service
chmod 0644 /etc/systemd/system/gha.service
systemctl enable gha.service

# Install systemd service for litestream.
cat <<EOF > /etc/systemd/system/litestream.service
[Unit]
Description=Litestream

[Service]
Restart=on-failure
ExecStart=/usr/local/bin/litestream

[Install]
WantedBy=multi-user.target
EOF

chown root:root /etc/systemd/system/litestream.service
chmod 0644 /etc/systemd/system/litestream.service
systemctl enable litestream.service

# Install litestream configuration.
cat <<EOF > /etc/litestream.yml 
databases:
  - path: /var/lib/gha/db
    replicas:
      - type: file
        path: /mnt/backup/gha/db
EOF

# Configure data & configuration directories.
mkdir -p /var/lib/gha && chown gha:gha /var/lib/gha && chmod 755 /var/lib/gha

# Create mount directory for replication.
mkdir -p /mnt/backup
mount -o discard,defaults,noatime /dev/disk/by-id/scsi-0DO_Volume_volume-nyc3-01 /mnt/backup
echo '/dev/disk/by-id/scsi-0DO_Volume_volume-nyc3-01 /mnt/backup ext4 defaults,nofail,discard 0 0' | sudo tee -a /etc/fstab

# Configure & enable firewall.
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow 7070 # metrics
ufw --force enable

# Disable root access & password authentication.
lineinfile "/etc/ssh/sshd_config" "^PermitRootLogin .*" "PermitRootLogin no"
lineinfile "/etc/ssh/sshd_config" "^PasswordAuthentication .*" "PasswordAuthentication no"
service sshd restart