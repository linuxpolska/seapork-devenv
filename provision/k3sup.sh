#!/bin/bash

export robot_domain=robot.example.com
export public_dns=8.8.8.8

export gitadmin=robokot
export gitpass=dupa.8
export git_domain=git.${robot_domain}

export regadmin=robokot
export regpass=dupa.8
export reg_domain=docker-registry.${robot_domain}

export metal_secretkey=$(openssl rand -base64 128)
export metal_range=10.142.42.100-10.142.42.200

function get_url() {
  i=0
  while ! curl -sLS -o $2 $1 ; do
    echo "Fetch failed for $1 -- will retry... ($i)"
    sleep 10
    i=$((i+1))
    if [ $i -gt 10 ] ; then
      break
    fi
  done
}

function install_url() {
  o=$(mktemp /tmp/exec_XXXXXX)
  get_url $1 $o
  chmod u+x $o
  $o
  rm -f $o
}

set -ex

cd /tmp

# install dnsmasq
apt update
apt -y install dnsmasq
systemctl disable systemd-resolved
systemctl stop systemd-resolved
rm -f /etc/resolv.conf
export top_domain=$(echo "$robot_domain"|sed -e 's/^[^\.]*\.//')
export kube_domain=cluster.local
cat <<. >/etc/resolv.conf
nameserver 127.0.0.1
search default.svc.${kube_domain} svc.${kube_domain} ${kube_domain} ${robot_domain} ${top_domain}
.
cat <<. >/etc/resolv.conf.k3s
nameserver 10.0.2.15
search ${robot_domain} ${top_domain}
.
cat <<. >/etc/dnsmasq.conf
port=53
listen-address=127.0.0.1
listen-address=10.0.2.15
expand-hosts
server=${public_dns}
server=/${kube_domain}/10.43.0.10
.
systemctl enable dnsmasq
systemctl restart dnsmasq || systemctl start dnsmasq

# install k3sup
[ -f /usr/local/bin/k3sup ] || install_url https://get.k3sup.dev
[ -f /tmp/k3sup ] && install /tmp/k3sup /usr/local/bin/

# install arkade
[ -f /usr/local/bin/arkade ] || install_url https://get.arkade.dev
arkade get yq
install /root/.arkade/bin/yq /usr/local/bin/

# install k3s
if [ ! -f ~/.kube/config ] ; then
  k3sup install --local --k3s-extra-args '--no-deploy traefik --resolv-conf /etc/resolv.conf.k3s'
  mkdir ~/.kube
  mv /tmp/kubeconfig ~/.kube/config
  kubectl get node
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.4/manifests/namespace.yaml
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.4/manifests/metallb.yaml
  kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="${metal_secretkey}"
  cat <<. >/tmp/metallb-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
    namespace: metallb-system
    name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${metal_range}
.
  kubectl apply -f metallb-config.yaml
  cat <<. >/etc/rancher/k3s/registries.yaml
---
mirrors:
  ${reg_domain}:
    endpoint:
      - "http://docker-registry.default.svc.cluster.local:5000"
  "docker-registry.default.svc.cluster.local:5000":
    endpoint:
      - "http://docker-registry.default.svc.cluster.local:5000"
configs:
  "docker-registry.default.svc.cluster.local:5000":
    auth:
      username: ${regadmin}
      password: ${regpass}
.
  systemctl restart k3s
fi

if kubectl get node ; then
  kube_ready=1
else
  kube_ready=''
fi

# install helm
if [ ! -f /usr/local/bin/helm ] ; then
  install_url https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
fi

# install docker
if [ ! -f /usr/bin/docker ] ; then
  apt update
  apt -y install apt-transport-https ca-certificates software-properties-common make
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu bionic stable"
  apt update
  apt -y install docker-ce
  cat <<. >/etc/docker/daemon.json
{ "insecure-registries": [ "docker-registry.default.svc.cluster.local:5000" ] }
.
  systemctl enable docker
  systemctl restart docker || systemctl start docker
  docker run hello-world
fi

# install operator sdk
if [ ! -f /usr/local/bin/operator-sdk ] ; then
  export ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n $(uname -m) ;; esac)
  export OS=$(uname | awk '{print tolower($0)}')
  export OPERATOR_SDK_DL_URL=https://github.com/operator-framework/operator-sdk/releases/download/v1.13.1
  export CORES=$(cat /proc/cpuinfo |grep cores|tail -1|cut -f2 -d:|tr -d ' ')
  curl -sLSO ${OPERATOR_SDK_DL_URL}/operator-sdk_${OS}_${ARCH}
  chmod +x operator-sdk_${OS}_${ARCH} 
  install operator-sdk_${OS}_${ARCH} /usr/local/bin/operator-sdk
  [ $CORES -gt 1 ] && operator-sdk olm install
fi

# install docker registry
arkade install docker-registry -u ${regadmin} -p ${regpass}

# install ingress-nginx
ingress_ready=$(kubectl get pods|grep ingress-nginx|grep Running||:)
if [ ! -z "$kube_ready" ] && [ -z "$ingress_ready" ] ; then
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update
  helm install home ingress-nginx/ingress-nginx
  kubectl --namespace default get services -o wide home-ingress-nginx-controller
fi

# install gitea
gitea_ready=$(kubectl get pods -n gitea|grep gitea-0|grep Running||:)
if [ ! -z "$kube_ready" ] && [ -z "$gitea_ready" ] ; then
  helm repo add gitea-charts https://dl.gitea.io/charts/
  cat <<. >/tmp/gitea-values.yml
ingress:
  hosts:
    - host: ${git_domain}
      paths:
        - path: /
          pathType: Prefix

gitea:
  admin:
    username: ${gitadmin}
    password: ${gitpass}
    email: "robot1@linuxpolska.pl"
.
  kubectl create ns gitea
  helm install gitea gitea-charts/gitea -n gitea -f /tmp/gitea-values.yml
  cat <<. >/tmp/gitea-ingress.yml
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
  name: gitea-http-ingress
  namespace: gitea
spec:
  rules:
    - host: ${git_domain}
      http:
        paths:
          - backend:
              serviceName: gitea-http
              servicePort: 3000
            path: /
.
  while ! kubectl create -f /tmp/gitea-ingress.yml ; do echo "Ingress not ready yet - will retry..." ; sleep 10 ; done
fi

# install tea
if [ ! -f /usr/local/bin/tea ] ; then
  curl -sLS https://gitea.com/attachments/bba60977-7066-4376-b232-941855b6015b >/tmp/tea
  chmod a+x /tmp/tea
  install /tmp/tea /usr/local/bin/
  tea login add -u http://${git_domain}/ --user ${gitadmin} --password ${gitpass}
fi

# customize jenkins x
if [ ! -d /tmp/jx3-kubernetes ] ; then
  git clone https://github.com/jx3-gitops-repositories/jx3-kubernetes
  tea repo create --name jx3-kubernetes --branch main --init
  cd jx3-kubernetes/
  git remote remove origin
  git remote add origin http://${gitadmin}:${gitpass}@${git_domain}/${gitadmin}/jx3-kubernetes
  perl -pi -e "s/domain: .*/domain: ${robot_domain}/" jx-requirements.yml
  git add .
  git commit -m domain
  git push --set-upstream origin main -f
  cd /tmp
fi

# install jenkins x
if [ ! -f /usr/local/bin/jx ] ; then
  curl -sLS https://github.com/jenkins-x/jx/releases/download/v3.2.207/jx-linux-amd64.tar.gz | tar xzv
  chmod +x /tmp/jx
  install /tmp/jx /usr/local/bin
fi
jx admin operator --url=http://${git_domain}/${gitadmin}/jx3-kubernetes --username ${gitadmin} --token ${gitpass}
jx_pass=$(kubectl get secret jx-basic-auth-user-password -o jsonpath="{.data.password}" -n jx | base64 --decode)

cat <<.

Provision complete.

Jenkins X login:

  URL      : http://dashboard-jx.${robot_domain}/
  Login    : admin
  Password : ${jx_pass}

Gitea login:

  URL      : http://${git_domain}/
  Login    : ${gitadmin}
  Password : ${gitpass}

Registry login:

  URL      : docker-registry.default.svc.cluster.local:5000
  Login    : ${regadmin}
  Password : ${regpass}

.

