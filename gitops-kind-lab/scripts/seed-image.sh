#!/usr/bin/env bash
# Build the sample app on the host and push the init tag Argo CD expects.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-init}"

docker build -t "localhost:5001/demo-app:${TAG}" "${ROOT}/sample-app"
docker push "localhost:5001/demo-app:${TAG}"
echo "Pushed localhost:5001/demo-app:${TAG}"
