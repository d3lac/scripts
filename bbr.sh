#!/bin/bash
#curl -LsO https://raw.githubusercontent.com/d3lac/scripts/main/bbr.sh; bash bbr.sh
grep 'CONFIG_TCP_CONG_BBR' /boot/config-$(uname -r)
sleep 2
grep 'CONFIG_NET_SCH_FQ' /boot/config-$(uname -r)
sleep 2
egrep 'CONFIG_TCP_CONG_BBR|CONFIG_NET_SCH_FQ' /boot/config-$(uname -r)
sleep 2
echo 'net.core.default_qdisc=fq' | sudo tee -a /etc/sysctl.conf
echo 'net.ipv4.tcp_congestion_control=bbr' | sudo tee -a /etc/sysctl.conf
sudo sysctl --system
