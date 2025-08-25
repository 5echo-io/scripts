#!/bin/bash
set -e

echo "### Installing Docker..."
curl -fsSL https://get.docker.com | bash

echo "### Adding current user to docker group..."
sudo usermod -aG docker $USER

echo "### Enabling Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

echo "### Docker installation complete!"
docker --version
