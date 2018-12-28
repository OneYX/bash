### [centos7使用kubeadm安装kubernetes 1.11版本多主高可用](https://www.kubernetes.org.cn/4256.html)

### 实验环境说明

#### 实验架构图

```
lab1: etcd master haproxy keepalived 11.11.11.111
lab2: etcd master haproxy keepalived 11.11.11.112
lab3: etcd master haproxy keepalived 11.11.11.113
lab4: node  11.11.11.114
lab5: node  11.11.11.115
lab6: node  11.11.11.116

vip(loadblancer ip): 11.11.11.110
```

#### 实验使用的`Vagrantfile`

```
# -*- mode: ruby -*-
# vi: set ft=ruby :

ENV["LC_ALL"] = "en_US.UTF-8"

Vagrant.configure("2") do |config|
    (1..6).each do |i|
      config.vm.define "lab#{i}" do |node|
        node.vm.box = "centos-7.4-docker-17"
        node.ssh.insert_key = false
        node.vm.hostname = "lab#{i}"
        node.vm.network "private_network", ip: "11.11.11.11#{i}"
        node.vm.provision "shell",
          inline: "echo hello from node #{i}"
        node.vm.provider "virtualbox" do |v|
          v.cpus = 2
          v.customize ["modifyvm", :id, "--name", "lab#{i}", "--memory", "2048"]
        end
      end
    end
end
```

### 安装配置docker

> v1.11.0版本推荐使用docker v17.03,
> v1.11,v1.12,v1.13, 也可以使用，再高版本的docker可能无法正常使用。
> 测试发现17.09无法正常使用，不能使用资源限制(内存CPU)
>
> 如下操作在所有节点操作

#### 安装docker

```sh
# 卸载安装指定版本docker-ce
yum remove -y docker-ce docker-ce-selinux container-selinux
yum install -y --setopt=obsoletes=0 \
docker-ce-17.03.1.ce-1.el7.centos \
docker-ce-selinux-17.03.1.ce-1.el7.centos
```

#### 启动docker

```sh
systemctl enable docker && systemctl restart docker
```

### 安装 kubeadm, kubelet 和 kubectl

> 如下操作在所有节点操作

#### 使用阿里镜像安装

```sh
# 配置源
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF

# 安装
yum install -y kubelet kubeadm kubectl ipvsadm
```

### 配置系统相关参数

```sh
# 临时禁用selinux
# 永久关闭 修改/etc/sysconfig/selinux文件设置
sed -i 's/SELINUX=permissive/SELINUX=disabled/' /etc/sysconfig/selinux
setenforce 0

# 临时关闭swap
# 永久关闭 注释/etc/fstab文件里swap相关的行
swapoff -a

# 开启forward
# Docker从1.13版本开始调整了默认的防火墙规则
# 禁用了iptables filter表中FOWARD链
# 这样会引起Kubernetes集群中跨Node的Pod无法通信

iptables -P FORWARD ACCEPT

# 配置转发相关参数，否则可能会出错
cat <<EOF >  /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
vm.swappiness=0
EOF
sysctl --system

# 加载ipvs相关内核模块
# 如果重新开机，需要重新加载
modprobe ip_vs
modprobe ip_vs_rr
modprobe ip_vs_wrr
modprobe ip_vs_sh
modprobe nf_conntrack_ipv4
lsmod | grep ip_vs
```

### 配置hosts解析

> 如下操作在所有节点操作

```sh
cat >>/etc/hosts<<EOF
11.11.11.111 lab1
11.11.11.112 lab2
11.11.11.113 lab3
11.11.11.114 lab4
11.11.11.115 lab5
11.11.11.116 lab6
EOF
```

### 配置haproxy代理和keepalived

> 如下操作在节点`lab1,lab2,lab3`操作

```sh
# 拉取haproxy镜像
docker pull haproxy:1.7.8-alpine
mkdir /etc/haproxy
cat >/etc/haproxy/haproxy.cfg<<EOF
global
  log 127.0.0.1 local0 err
  maxconn 50000
  uid 99
  gid 99
  #daemon
  nbproc 1
  pidfile haproxy.pid

defaults
  mode http
  log 127.0.0.1 local0 err
  maxconn 50000
  retries 3
  timeout connect 5s
  timeout client 30s
  timeout server 30s
  timeout check 2s

listen admin_stats
  mode http
  bind 0.0.0.0:1080
  log 127.0.0.1 local0 err
  stats refresh 30s
  stats uri     /haproxy-status
  stats realm   Haproxy\ Statistics
  stats auth    will:will
  stats hide-version
  stats admin if TRUE

frontend k8s-https
  bind 0.0.0.0:8443
  mode tcp
  #maxconn 50000
  default_backend k8s-https

backend k8s-https
  mode tcp
  balance roundrobin
  server lab1 11.11.11.111:6443 weight 1 maxconn 1000 check inter 2000 rise 2 fall 3
  server lab2 11.11.11.112:6443 weight 1 maxconn 1000 check inter 2000 rise 2 fall 3
  server lab3 11.11.11.113:6443 weight 1 maxconn 1000 check inter 2000 rise 2 fall 3
EOF

# 启动haproxy
docker run -d --name my-haproxy \
-v /etc/haproxy:/usr/local/etc/haproxy:ro \
-p 8443:8443 \
-p 1080:1080 \
--restart always \
haproxy:1.7.8-alpine

# 查看日志
docker logs my-haproxy

# 浏览器查看状态
http://11.11.11.111:1080/haproxy-status
http://11.11.11.112:1080/haproxy-status

# 拉取keepalived镜像
docker pull osixia/keepalived:1.4.4

# 启动
# 载入内核相关模块
lsmod | grep ip_vs
modprobe ip_vs

# 启动keepalived
# eth1为本次实验11.11.11.0/24网段的所在网卡
docker run --net=host --cap-add=NET_ADMIN \
-e KEEPALIVED_INTERFACE=eth1 \
-e KEEPALIVED_VIRTUAL_IPS="#PYTHON2BASH:['11.11.11.110']" \
-e KEEPALIVED_UNICAST_PEERS="#PYTHON2BASH:['11.11.11.111','11.11.11.112','11.11.11.113']" \
-e KEEPALIVED_PASSWORD=hello \
--name k8s-keepalived \
--restart always \
-d osixia/keepalived:1.4.4

# 查看日志
# 会看到两个成为backup 一个成为master
docker logs k8s-keepalived

# 此时会配置 11.11.11.110 到其中一台机器
# ping测试
ping -c4 11.11.11.110

# 如果失败后清理后，重新实验
docker rm -f k8s-keepalived
ip a del 11.11.11.110/32 dev eth1
```

### 配置启动kubelet

> 如下操作在所有节点操作

```sh
# 配置kubelet使用国内pause镜像
# 配置kubelet的cgroups
# 获取docker的cgroups
DOCKER_CGROUPS=$(docker info | grep 'Cgroup' | cut -d' ' -f3)
echo $DOCKER_CGROUPS
cat >/etc/sysconfig/kubelet<<EOF
KUBELET_EXTRA_ARGS="--cgroup-driver=$DOCKER_CGROUPS --pod-infra-container-image=registry.cn-hangzhou.aliyuncs.com/google_containers/pause-amd64:3.1"
EOF

# 启动
systemctl daemon-reload
systemctl enable kubelet && systemctl restart kubelet
```

### 配置master

#### 配置第一个master节点

> 如下操作在`lab1`节点操作

```sh
# 1.11 版本 centos 下使用 ipvs 模式会出问题
# 参考 https://github.com/kubernetes/kubernetes/issues/65461

# 生成配置文件
CP0_IP="11.11.11.111"
CP0_HOSTNAME="lab1"
cat >kubeadm-master.config<<EOF
apiVersion: kubeadm.k8s.io/v1alpha2
kind: MasterConfiguration
kubernetesVersion: v1.11.0
imageRepository: registry.cn-hangzhou.aliyuncs.com/google_containers

apiServerCertSANs:
- "lab1"
- "lab2"
- "lab3"
- "11.11.11.111"
- "11.11.11.112"
- "11.11.11.113"
- "11.11.11.110"
- "127.0.0.1"

api:
  advertiseAddress: $CP0_IP
  controlPlaneEndpoint: 11.11.11.110:8443

etcd:
  local:
    extraArgs:
      listen-client-urls: "https://127.0.0.1:2379,https://$CP0_IP:2379"
      advertise-client-urls: "https://$CP0_IP:2379"
      listen-peer-urls: "https://$CP0_IP:2380"
      initial-advertise-peer-urls: "https://$CP0_IP:2380"
      initial-cluster: "$CP0_HOSTNAME=https://$CP0_IP:2380"
    serverCertSANs:
      - $CP0_HOSTNAME
      - $CP0_IP
    peerCertSANs:
      - $CP0_HOSTNAME
      - $CP0_IP

controllerManagerExtraArgs:
  node-monitor-grace-period: 10s
  pod-eviction-timeout: 10s

networking:
  podSubnet: 10.244.0.0/16
  
kubeProxy:
  config:
    # mode: ipvs
    mode: iptables
EOF

# 提前拉取镜像
# 如果执行失败 可以多次执行
kubeadm config images pull --config kubeadm-master.config

# 初始化
# 注意保存返回的 join 命令
kubeadm init --config kubeadm-master.config

# 打包ca相关文件上传至其他master节点
cd /etc/kubernetes && tar cvzf k8s-key.tgz admin.conf pki/ca.* pki/sa.* pki/front-proxy-ca.* pki/etcd/ca.*
scp k8s-key.tgz lab2:~/
scp k8s-key.tgz lab3:~/
ssh lab2 'tar xf k8s-key.tgz -C /etc/kubernetes/'
ssh lab3 'tar xf k8s-key.tgz -C /etc/kubernetes/'
```

#### 配置第二个master节点

> 如下操作在`lab2`节点操作

```sh
# 1.11 版本 centos 下使用 ipvs 模式会出问题
# 参考 https://github.com/kubernetes/kubernetes/issues/65461

# 生成配置文件
CP0_IP="11.11.11.111"
CP0_HOSTNAME="lab1"
CP1_IP="11.11.11.112"
CP1_HOSTNAME="lab2"
cat >kubeadm-master.config<<EOF
apiVersion: kubeadm.k8s.io/v1alpha2
kind: MasterConfiguration
kubernetesVersion: v1.11.0
imageRepository: registry.cn-hangzhou.aliyuncs.com/google_containers

apiServerCertSANs:
- "lab1"
- "lab2"
- "lab3"
- "11.11.11.111"
- "11.11.11.112"
- "11.11.11.113"
- "11.11.11.110"
- "127.0.0.1"

api:
  advertiseAddress: $CP1_IP
  controlPlaneEndpoint: 11.11.11.110:8443

etcd:
  local:
    extraArgs:
      listen-client-urls: "https://127.0.0.1:2379,https://$CP1_IP:2379"
      advertise-client-urls: "https://$CP1_IP:2379"
      listen-peer-urls: "https://$CP1_IP:2380"
      initial-advertise-peer-urls: "https://$CP1_IP:2380"
      initial-cluster: "$CP0_HOSTNAME=https://$CP0_IP:2380,$CP1_HOSTNAME=https://$CP1_IP:2380"
      initial-cluster-state: existing
    serverCertSANs:
      - $CP1_HOSTNAME
      - $CP1_IP
    peerCertSANs:
      - $CP1_HOSTNAME
      - $CP1_IP

controllerManagerExtraArgs:
  node-monitor-grace-period: 10s
  pod-eviction-timeout: 10s

networking:
  podSubnet: 10.244.0.0/16
  
kubeProxy:
  config:
    # mode: ipvs
    mode: iptables
EOF

# 配置kubelet
kubeadm alpha phase certs all --config kubeadm-master.config
kubeadm alpha phase kubelet config write-to-disk --config kubeadm-master.config
kubeadm alpha phase kubelet write-env-file --config kubeadm-master.config
kubeadm alpha phase kubeconfig kubelet --config kubeadm-master.config
systemctl restart kubelet

# 添加etcd到集群中
CP0_IP="11.11.11.111"
CP0_HOSTNAME="lab1"
CP1_IP="11.11.11.112"
CP1_HOSTNAME="lab2"
KUBECONFIG=/etc/kubernetes/admin.conf kubectl exec -n kube-system etcd-${CP0_HOSTNAME} -- etcdctl --ca-file /etc/kubernetes/pki/etcd/ca.crt --cert-file /etc/kubernetes/pki/etcd/peer.crt --key-file /etc/kubernetes/pki/etcd/peer.key --endpoints=https://${CP0_IP}:2379 member add ${CP1_HOSTNAME} https://${CP1_IP}:2380
kubeadm alpha phase etcd local --config kubeadm-master.config

# 提前拉取镜像
# 如果执行失败 可以多次执行
kubeadm config images pull --config kubeadm-master.config

# 部署
kubeadm alpha phase kubeconfig all --config kubeadm-master.config
kubeadm alpha phase controlplane all --config kubeadm-master.config
kubeadm alpha phase mark-master --config kubeadm-master.config
```

#### 配置第三个master节点

> 如下操作在`lab3`节点操作

```sh
# 1.11 版本 centos 下使用 ipvs 模式会出问题
# 参考 https://github.com/kubernetes/kubernetes/issues/65461

# 生成配置文件
CP0_IP="11.11.11.111"
CP0_HOSTNAME="lab1"
CP1_IP="11.11.11.112"
CP1_HOSTNAME="lab2"
CP2_IP="11.11.11.113"
CP2_HOSTNAME="lab3"
cat >kubeadm-master.config<<EOF
apiVersion: kubeadm.k8s.io/v1alpha2
kind: MasterConfiguration
kubernetesVersion: v1.11.0
imageRepository: registry.cn-hangzhou.aliyuncs.com/google_containers

apiServerCertSANs:
- "lab1"
- "lab2"
- "lab3"
- "11.11.11.111"
- "11.11.11.112"
- "11.11.11.113"
- "11.11.11.110"
- "127.0.0.1"

api:
  advertiseAddress: $CP2_IP
  controlPlaneEndpoint: 11.11.11.110:8443

etcd:
  local:
    extraArgs:
      listen-client-urls: "https://127.0.0.1:2379,https://$CP2_IP:2379"
      advertise-client-urls: "https://$CP2_IP:2379"
      listen-peer-urls: "https://$CP2_IP:2380"
      initial-advertise-peer-urls: "https://$CP2_IP:2380"
      initial-cluster: "$CP0_HOSTNAME=https://$CP0_IP:2380,$CP1_HOSTNAME=https://$CP1_IP:2380,$CP2_HOSTNAME=https://$CP2_IP:2380"
      initial-cluster-state: existing
    serverCertSANs:
      - $CP2_HOSTNAME
      - $CP2_IP
    peerCertSANs:
      - $CP2_HOSTNAME
      - $CP2_IP

controllerManagerExtraArgs:
  node-monitor-grace-period: 10s
  pod-eviction-timeout: 10s

networking:
  podSubnet: 10.244.0.0/16
  
kubeProxy:
  config:
    # mode: ipvs
    mode: iptables
EOF

# 配置kubelet
kubeadm alpha phase certs all --config kubeadm-master.config
kubeadm alpha phase kubelet config write-to-disk --config kubeadm-master.config
kubeadm alpha phase kubelet write-env-file --config kubeadm-master.config
kubeadm alpha phase kubeconfig kubelet --config kubeadm-master.config
systemctl restart kubelet

# 添加etcd到集群中
CP0_IP="11.11.11.111"
CP0_HOSTNAME="lab1"
CP2_IP="11.11.11.113"
CP2_HOSTNAME="lab3"
KUBECONFIG=/etc/kubernetes/admin.conf kubectl exec -n kube-system etcd-${CP0_HOSTNAME} -- etcdctl --ca-file /etc/kubernetes/pki/etcd/ca.crt --cert-file /etc/kubernetes/pki/etcd/peer.crt --key-file /etc/kubernetes/pki/etcd/peer.key --endpoints=https://${CP0_IP}:2379 member add ${CP2_HOSTNAME} https://${CP2_IP}:2380
kubeadm alpha phase etcd local --config kubeadm-master.config

# 提前拉取镜像
# 如果执行失败 可以多次执行
kubeadm config images pull --config kubeadm-master.config

# 部署
kubeadm alpha phase kubeconfig all --config kubeadm-master.config
kubeadm alpha phase controlplane all --config kubeadm-master.config
kubeadm alpha phase mark-master --config kubeadm-master.config
```

### 配置使用kubectl

> 如下操作在任意`master`节点操作

```sh
rm -rf $HOME/.kube
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 查看node节点
kubectl get nodes

# 只有网络插件也安装配置完成之后，才能会显示为ready状态
# 设置master允许部署应用pod，参与工作负载，现在可以部署其他系统组件
# 如 dashboard, heapster, efk等
kubectl taint nodes --all node-role.kubernetes.io/master-
```

### 配置使用网络插件

> 如下操作在任意`master`节点操作

```sh
# 下载配置
mkdir flannel && cd flannel
wget https://raw.githubusercontent.com/coreos/flannel/v0.10.0/Documentation/kube-flannel.yml

# 修改配置
# 此处的ip配置要与上面kubeadm的pod-network一致
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "Backend": {
        "Type": "vxlan"
      }
    }

# 修改镜像
image: registry.cn-shanghai.aliyuncs.com/gcr-k8s/flannel:v0.10.0-amd64

# 如果Node有多个网卡的话，参考flannel issues 39701，
# https://github.com/kubernetes/kubernetes/issues/39701
# 目前需要在kube-flannel.yml中使用--iface参数指定集群主机内网网卡的名称，
# 否则可能会出现dns无法解析。容器无法通信的情况，需要将kube-flannel.yml下载到本地，
# flanneld启动参数加上--iface=<iface-name>
    containers:
      - name: kube-flannel
        image: registry.cn-shanghai.aliyuncs.com/gcr-k8s/flannel:v0.10.0-amd64
        command:
        - /opt/bin/flanneld
        args:
        - --ip-masq
        - --kube-subnet-mgr
        - --iface=eth1

# 启动
kubectl apply -f kube-flannel.yml

# 查看
kubectl get pods --namespace kube-system
kubectl get svc --namespace kube-system
```

### 配置node节点加入集群

> 如下操作在所有`node`节点操作

```sh
# 此命令为初始化master成功后返回的结果
kubeadm join 11.11.11.110:8443 --token yzb7v7.dy40mhlljt1d48i9 --discovery-token-ca-cert-hash sha256:61ec309e6f942305006e6622dcadedcc64420e361231eff23cb535a183c0e77a
```

### 基础测试

#### 测试容器间的通信和DNS

> 配置好网络之后，kubeadm会自动部署coredns
>
> 如下测试可以在配置kubectl的节点上操作

##### 启动

```sh
kubectl run nginx --replicas=2 --image=nginx:alpine --port=80
kubectl expose deployment nginx --type=NodePort --name=example-service-nodeport
kubectl expose deployment nginx --name=example-service
```

##### 查看状态

```sh
kubectl get deploy
kubectl get pods
kubectl get svc
kubectl describe svc example-service
```

##### DNS解析

```sh
kubectl run curl --image=radial/busyboxplus:curl -i --tty
nslookup kubernetes
nslookup example-service
curl example-service
```

##### 访问测试

```sh
# 10.96.59.56 为查看svc时获取到的clusterip
curl "10.96.59.56:80"

# 32223 为查看svc时获取到的 nodeport
http://11.11.11.112:32223/
http://11.11.11.113:32223/
```

##### 清理删除

```sh
kubectl delete svc example-service example-service-nodeport
kubectl delete deploy nginx curl
```

### 高可用测试

关闭任一`master`节点测试集群是能否正常执行上一步的`基础测试`，查看相关信息，不能同时关闭两个节点，因为3个节点组成的`etcd`集群，最多只能有一个当机。

```sh
# 查看组件状态
kubectl get pod --all-namespaces -o wide
kubectl get pod --all-namespaces -o wide | grep lab1
kubectl get pod --all-namespaces -o wide | grep lab2
kubectl get pod --all-namespaces -o wide | grep lab3
kubectl get nodes -o wide
kubectl get deploy
kubectl get pods
kubectl get svc

# 访问测试
CURL_POD=$(kubectl get pods | grep curl | grep Running | cut -d ' ' -f1)
kubectl exec -ti $CURL_POD -- sh --tty
nslookup kubernetes
nslookup example-service
curl example-service
```

### 小技巧

**忘记初始master节点时的node节点加入集群命令怎么办**

```sh
# 简单方法
kubeadm token create --print-join-command

# 第二种方法
token=$(kubeadm token generate)
kubeadm token create $token --print-join-command --ttl=0
```

### 参考文档

- <https://kubernetes.io/docs/setup/independent/install-kubeadm/>
- <https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/>
- <https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/>
- <https://kubernetes.io/docs/setup/independent/high-availability/>
- <https://sealyun.com/post/k8s-ipvs/>
- <http://www.maogx.win/posts/33/>
