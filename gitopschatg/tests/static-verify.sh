#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
J="$ROOT_DIR/seed/app-repo/Jenkinsfile"

for forbidden in 'kubectl apply' 'kubectl set image' 'helm upgrade' 'terraform apply'; do
  if grep -Fq "$forbidden" "$J"; then
    echo "FAIL: Jenkinsfile contains forbidden deploy command: $forbidden"
    exit 1
  fi
done

grep -Fq "gradle --no-daemon clean test" "$J"
grep -Fq "gradle --no-daemon jib" "$J"
grep -Fq "newTag" "$J"
grep -Fq "Argo CD" "$J"

echo "PASS: Jenkinsfile obeys build -> Git only deployment boundary."
