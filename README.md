# devenv

Development environment for Robot Project with Vagrant, K3S and friends.

## Getting started

It takes ~10 minutes to provision a server.

```
git clone https://gitlab.com/linux-polska/robot/devenv.git
cd devenv
vagrant up
```

## Getting in

K3s takes over iptables. Therefore it won't be possible to do ```vagrant ssh``` (it will time out). Luckily we still can connect to public-facing inerface:

```
ssh -i .vagrant/machines/robot1/virtualbox/private_key vagrant@robot1.robot.example.com
```
