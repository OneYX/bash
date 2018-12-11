##### 1. 关闭交换分区
- `swapoff -a`
- `sed -i '/swap/s/^/#/' /etc/fstab`
##### 2. 安装Docker
`curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun` or 
``` bash
# step 1: 安装必要的一些系统工具
sudo yum install -y yum-utils device-mapper-persistent-data lvm2
# Step 2: 添加软件源信息
sudo yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
# Step 3: 更新并安装 Docker-CE
sudo yum makecache fast
sudo yum -y install docker-ce
# Step 4: 开启Docker服务
sudo service docker start

# 注意：
# 官方软件源默认启用了最新的软件，您可以通过编辑软件源的方式获取各个版本的软件包。例如官方并没有将测试版本的软件源置为可用，你可以通过以下方式开启。同理可以开启各种测试版本等。
# vim /etc/yum.repos.d/docker-ce.repo
#   将 [docker-ce-test] 下方的 enabled=0 修改为 enabled=1
#
# 安装指定版本的Docker-CE:
# Step 1: 查找Docker-CE的版本:
# yum list docker-ce.x86_64 --showduplicates | sort -r
#   Loading mirror speeds from cached hostfile
#   Loaded plugins: branch, fastestmirror, langpacks
#   docker-ce.x86_64            17.03.1.ce-1.el7.centos            docker-ce-stable
#   docker-ce.x86_64            17.03.1.ce-1.el7.centos            @docker-ce-stable
#   docker-ce.x86_64            17.03.0.ce-1.el7.centos            docker-ce-stable
#   Available Packages
# Step2 : 安装指定版本的Docker-CE: (VERSION 例如上面的 17.03.0.ce.1-1.el7.centos)
# sudo yum -y install docker-ce-[VERSION]
```
##### 3. 安装Kubernetes
``` bash
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
setenforce 0
yum install -y kubelet kubeadm kubectl
systemctl enable kubelet && systemctl start kubelet
```
##### 4. 拉取镜像
- k8s-images.sh
``` bash
#!/bin/bash
if [ x$1 == x ]; then
  echo 'version is not null'
  exit
fi

images=$(kubeadm config images list --kubernetes-version $1)
#or
#images=$(cat <<EOF
# gcr.io/google-containers/federation-controller-manager-arm64:v1.3.1-beta.1
# gcr.io/google-containers/federation-controller-manager-arm64:v1.3.1-beta.1
# gcr.io/google-containers/federation-controller-manager-arm64:v1.3.1-beta.1
#EOF
#)

eval $(echo ${images}|
        sed 's/k8s\.gcr\.io/gcr.mirrors.ustc.edu.cn\/google-containers/g;s/gcr\.io/gcr.mirrors.ustc.edu.cn/g;s/ /\n/g;s/gcr.mirrors.ustc.edu.cn\./gcr.mirrors.ustc.edu.cn\//g' |
        uniq |
        awk '{print "docker pull "$1";"}'
       )

# this code will retag all of gcr.mirrors.ustc.edu.cn's image from local  e.g. gcr.mirrors.ustc.edu.cn/google-containers.federation-controller-manager-arm64:v1.3.1-beta.1
# to gcr.io/google-containers/federation-controller-manager-arm64:v1.3.1-beta.1
# k8s.gcr.io/{image}/{tag} <==> gcr.io/google-containers/{image}/{tag} <==> gcr.mirrors.ustc.edu.cn/google-containers.{image}/{tag}

for img in $(docker images --format "{{.Repository}}:{{.Tag}}"| grep "gcr.mirrors.ustc.edu.cn"); do
  n=$(echo ${img}| awk -F'[/]' '{printf "gcr.io/%s",$2}')
  image=$(echo ${img}| awk -F'[/:]' '{printf "/%s",$3}')
  tag=$(echo ${img}| awk -F'[:]' '{printf ":%s",$2}')
  docker tag $img "${n}${image}${tag}"
  [[ ${n} == "gcr.io/google-containers" ]] && docker tag $img "k8s.gcr.io${image}${tag}"
  docker rmi $img
done
```
##### 5. 初始化主节点
- `systemctl stop firewalld`
- `kubeadm init --kubernetes-version=v1.13.0 --pod-network-cidr=10.244.0.0/16 --service-cidr=10.96.0.0/12 --ignore-preflight-errors=Swap` #--apiserver-advertise-address=192.168.56.101
##### 6. 部署网络
`kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml`
##### 7. 节点加入集群
`kubeadm join ...`
