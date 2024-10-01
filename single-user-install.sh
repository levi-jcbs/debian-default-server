# Function
function prompt() {
	echo -e "\n\033[1m$1\033[0m"
}

# Exit on error
set -e

# Check User
if [ $(whoami) != "root" ]; then
	echo "Please run as root."
	exit
fi

# Ask for data
read -p "SSH Public Key: " ssh_pubkey
read -p "Server Domain:  " domain_server
read -p "Cockpit Domain: " domain_cockpit

# Run Commands
prompt "Set Hostname and Timezone"
hostnamectl set-hostname $domain_server
timedatectl set-timezone Europe/Berlin

prompt "Fetch and Upgrade"
apt -y update && apt -y upgrade

prompt "Reducing Boot Timeout"
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
update-grub

prompt "Installing Firewall"
apt -y install firewalld

prompt "Fix systemd/cloud-init ordering cycle"
cp /lib/systemd/system/firewalld.service /etc/systemd/system/firewalld.service
sed -i 's/Before=.*/Before=network.target/' /etc/systemd/system/firewalld.service
sed -i '/Wants=.*/d' /etc/systemd/system/firewalld.service
systemctl daemon-reload
systemctl restart firewalld.service

prompt "Configure SSHD"
sed -i 's/^\(#\)\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^\(#\)\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^\(#\)\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^\(#\)\?AcceptEnv.*/#AcceptEnv LANG LC_*/' /etc/ssh/sshd_config
systemctl restart sshd.service

prompt "Create User"
useradd -m -s /bin/bash admin
sudo -iu admin mkdir /home/admin/.ssh/
echo "$ssh_pubkey" | sudo -iu admin tee -a /home/admin/.ssh/authorized_keys
usermod -aG sudo admin
loginctl enable-linger admin
sudo -iu admin mkdir -p /home/admin/.config/systemd/user/
sudo -iu admin ln -s /home/admin/.config/systemd/user/ /home/admin/systemd
sudo -iu admin mkdir -p /home/admin/apps/

prompt "Install Podman"
apt -y install podman slirp4netns uidmap containers-storage catatonit
sed -i 's/^\(# \)\?unqualified-search-registries =.*/unqualified-search-registries = \["docker.io", "ghcr.io"\]/' /etc/containers/registries.conf

prompt "Install Cockpit"
apt -y install cockpit cockpit-networkmanager cockpit-packagekit cockpit-pcp cockpit-podman cockpit-storaged libpam-google-authenticator
echo "# This file has been replaced by allowed-users with opposite behavior" | tee -a /etc/cockpit/disallowed-users
echo "admin" | tee -a /etc/cockpit/allowed-users
sed -i 's/pam_listfile.so item=user sense=deny file=\/etc\/cockpit\/disallowed-users onerr=succeed/pam_listfile.so item=user sense=allow file=\/etc\/cockpit\/allowed-users onerr=fail/' /etc/pam.d/cockpit
echo "[WebService]
Origins = https://$domain_cockpit wss://$domain_cockpit
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For
AllowUnencrypted = true" | tee -a /etc/cockpit/cockpit.conf
echo "
# TOTP-Authentication
auth required pam_google_authenticator.so" | tee -a /etc/pam.d/cockpit

prompt "Install Reverse Proxy"
firewall-cmd --permanent --zone=public --add-forward-port=port=80:proto=tcp:toport=8001
firewall-cmd --permanent --zone=public --add-forward-port=port=443:proto=tcp:toport=4001
sudo firewall-cmd --reload
sudo -iu admin mkdir -p /home/admin/apps/01_reverse-proxy/caddy/Caddyfiles/
sudo -iu admin mkdir /home/admin/apps/01_reverse-proxy/caddy/data/
sudo -iu admin mkdir /home/admin/apps/01_reverse-proxy/caddy/config/
echo "{
    http_port 8001
	https_port 4001
}

$domain_cockpit {
    reverse_proxy :9090
}" | sudo -iu admin tee -a /home/admin/apps/01_reverse-proxy/caddy/Caddyfiles/Caddyfile
sudo -iu admin podman pod create --replace --no-hosts --network host 01_reverse-proxy
sudo -iu admin podman container create --replace --pod 01_reverse-proxy --name 01_reverse-proxy_caddy -v /home/admin/apps/01_reverse-proxy/caddy/Caddyfiles/:/etc/caddy/ -v /home/admin/apps/01_reverse-proxy/caddy/config/:/config/ -v /home/admin/apps/01_reverse-proxy/caddy/data/:/data/ docker.io/library/caddy:2.8.4
sudo -iu admin sh -c 'cd /home/admin/systemd/; podman generate systemd --new --files --name 01_reverse-proxy'
sudo -iu admin podman pod rm 01_reverse-proxy
systemctl --user -M admin@ daemon-reload
systemctl --user -M admin@ enable pod-01_reverse-proxy.service

password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64)
prompt "Your admin password: $password"
echo "admin:$password" | chpasswd

prompt "Please enroll 2FA TOTP Authentication for cockpit"
sudo -iu admin google-authenticator -tfd --window-size=1 --rate-limit=3 --rate-time=30 --emergency-codes=0

prompt "System Reboot"
reboot
