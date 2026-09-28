#!/bin/bash

set -e

echo "Adding Flathub repository..."
sudo flatpak remote-add \
  --if-not-exists \
  flathub \
  https://flathub.org/repo/flathub.flatpakrepo

echo "Installing VLC..."
sudo flatpak install -y flathub org.videolan.VLC

echo "VLC installation completed."

# Verify
flatpak list | grep -i VLC
