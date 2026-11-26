sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y && sudo apt autoclean -y
sudo apt install unattended-upgrades && sudo dpkg-reconfigure --priority=low unattended-upgrades -u
