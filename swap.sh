#!/bin/bash
#curl -LsO https://raw.githubusercontent.com/d3lac/scripts/main/swap.sh; bash swap.sh
sudo swapon --show
#adds 2GB swap
echo "Enter numeric value Eg. 2 for 2GB allocation"
read sw
sudo fallocate -l $swG /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo free -h
