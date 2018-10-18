#!/bin/bash
cd "${0%/*}"

# backup sources
# cp /etc/apt/sources.list /etc/apt/sources.list.bak

codename=$(lsb_release -c | awk '{print $2}')

cat > /etc/apt/sources.list <<-EOF
deb http://mirrors.aliyun.com/ubuntu/ $codename main
deb-src http://mirrors.aliyun.com/ubuntu/ $codename main

deb http://mirrors.aliyun.com/ubuntu/ $codename-updates main
deb-src http://mirrors.aliyun.com/ubuntu/ $codename-updates main

deb http://mirrors.aliyun.com/ubuntu/ $codename universe
deb-src http://mirrors.aliyun.com/ubuntu/ $codename universe
deb http://mirrors.aliyun.com/ubuntu/ $codename-updates universe
deb-src http://mirrors.aliyun.com/ubuntu/ $codename-updates universe

deb http://mirrors.aliyun.com/ubuntu/ $codename-security main
deb-src http://mirrors.aliyun.com/ubuntu/ $codename-security main
deb http://mirrors.aliyun.com/ubuntu/ $codename-security universe
deb-src http://mirrors.aliyun.com/ubuntu/ $codename-security universe
EOF

curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun

apt-get update && apt-get install -y apt-transport-https
curl https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-$codename main
EOF
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# close swap
swapoff -a
sed -i /swap/d /etc/fstab

# set docker mirror
mkdir -p /etc/docker
tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": ["https://f9rczx9s.mirror.aliyuncs.com"]
}
EOF
systemctl daemon-reload
systemctl restart docker
