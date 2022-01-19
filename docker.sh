#!/bin/bash
#curl -LsO https://raw.githubusercontent.com/d3lac/scripts/main/docker.sh; bash docker.sh
curl -fsSL get.docker.com -o get-docker.sh && sudo sh get-docker.sh
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo docker --version
sudo docker-compose --version
