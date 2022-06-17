#!/bin/bash
#curl -LsO https://raw.githubusercontent.com/d3lac/scripts/main/docker.sh; bash docker.sh
curl -fsSL get.docker.com -o get-docker.sh && sudo sh get-docker.sh
DESTINATION=/usr/local/bin/docker-compose
sudo curl -L https://github.com/docker/compose/releases/download/${VERSION}/docker-compose-$(uname -s)-$(uname -m) -o $DESTINATION
sudo chmod 755 $DESTINATION
sudo systemctl enable docker
sudo systemctl start docker
sudo docker version
sudo docker compose --version
