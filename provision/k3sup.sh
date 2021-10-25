#!/bin/bash

export robot_url=robot.example.com

export gitadmin=robokot
export gitpass=dupa.8
export git_url=git.${robot_url}

export metal_secretkey=$(openssl rand -base64 128)
export metal_range=10.142.42.100-10.142.42.200

set -ex

cd /tmp

# install k3sup
[ -f /usr/local/bin/k3sup ] || curl -sLS https://get.k3sup.dev | sh
[ -f /tmp/k3sup ] && install /tmp/k3sup /usr/local/bin/

# install k3s
if [ ! -f ~/.kube/config ] ; then
  k3sup install --local --k3s-extra-args '--no-deploy traefik'
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
fi

if kubectl get node ; then
  kube_ready=1
else
  kube_ready=''
fi

# install helm
if [ ! -f /usr/local/bin/helm ] ; then
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh
fi

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
    - host: ${git_url}
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
    - host: ${git_url}
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
  tea login add -u http://${git_url}/ --user ${gitadmin} --password ${gitpass}
fi

# customize jenkins x
if [ ! -d /tmp/jx3-kubernetes ] ; then
  git clone https://github.com/jx3-gitops-repositories/jx3-kubernetes
  tea repo create --name jx3-kubernetes --branch main --init
  cd jx3-kubernetes/
  git remote remove origin
  git remote add origin http://${gitadmin}:${gitpass}@${git_url}/${gitadmin}/jx3-kubernetes
  perl -pi -e "s/domain: .*/domain: ${robot_url}/" jx-requirements.yml
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
jx admin operator --url=http://${git_url}/${gitadmin}/jx3-kubernetes --username ${gitadmin} --token ${gitpass}
jx_pass=$(kubectl get secret jx-basic-auth-user-password -o jsonpath="{.data.password}" -n jx | base64 --decode)

cat <<.

Provision complete.

Jenkins X login:

  URL      : http://dashboard-jx.${robot_url}/
  Login    : admin
  Password : ${jx_pass}

Gitea login:

  URL      : http://git.${robot_url}/
  Login    : ${gitadmin}
  Password : ${gitpass}

.

