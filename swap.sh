#!/bin/bash
#curl -LsO https://raw.githubusercontent.com/d3lac/scripts/main/swap.sh; bash swap.sh
sudo swapon --show
#adds 2GB swap
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo free -h
