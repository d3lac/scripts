#!/bin/bash
#curl -LsO https://raw.githubusercontent.com/d3lac/scripts/main/adduser.sh; bash adduser.sh
apt install -y sudo
echo "Enter the user name: "  
read name
useradd -m -s /bin/bash $name
passwd $name
usermod -aG sudo $name
