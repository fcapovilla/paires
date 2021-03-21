#!/bin/sh

cd "$(dirname "$0")"
set -e

cd ..
echo "REMEMBER: Login using 'docker login ghcr.io -u USERNAME -p TOKEN'"
rm -rf deps _build assets/node_modules
docker build -t ghcr.io/fcapovilla/paires:${1:-latest} -f release/Dockerfile .
docker push ghcr.io/fcapovilla/paires:${1:-latest}
