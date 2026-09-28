#!/usr/bin/env bash
# =============================================================================
#  tools/local-check.sh — every check that can run WITHOUT a cluster.
#
#  Think of it as the pre-flight inspection before you spend money on Azure:
#    1. shell scripts        bash -n + shellcheck (if installed)
#    2. k8s templates        render with envsubst, parse as YAML
#    3. realm JSON           valid JSON after placeholder substitution
#    4. Helm chart           render with tools/dev/minihelm (Go) or real helm, parse as YAML
#    5. Python deli          pytest (sqlite, no Keycloak needed)
#    6. Go inspector         go vet + go test (fake Keycloak/apps in the test)
#    7. Playwright           npx playwright test --list (parses the spec)
#    8. Java store           mvn compile if Maven is installed (else syntax-only via javalang, else skipped)
#
#  Usage: tools/local-check.sh            (run all)
#         tools/local-check.sh 1 4 6      (run only some)
# =============================================================================
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

PASS=0; FAIL=0; SKIP=0
pass() { printf '\033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '\033[1;33mSKIP\033[0m  %s\n' "$*"; SKIP=$((SKIP+1)); }
want() { local c; for c in "$@"; do [[ " ${ONLY[*]} " == *" $c "* ]] && return 0; done; [[ ${#ONLY[@]} -eq 0 ]]; }
ONLY=("$@")

# ---- 1. shell scripts -----------------------------------------------------------
if want 1; then
  ok=true
  for f in scripts/*.sh scripts/lib/common.sh tools/*.sh k8s/postgres/init.sh; do
    bash -n "$f" || { fail "bash -n $f"; ok=false; }
  done
  sh -n tests/curl-client/run-tests.sh || { fail "sh -n tests/curl-client/run-tests.sh"; ok=false; }
  if command -v shellcheck >/dev/null; then
    shellcheck -S warning scripts/*.sh scripts/lib/common.sh tools/*.sh || { fail "shellcheck (bash scripts)"; ok=false; }
    shellcheck -S warning -s sh tests/curl-client/run-tests.sh k8s/postgres/init.sh || { fail "shellcheck (sh scripts)"; ok=false; }
  else
    skip "shellcheck not installed (apt install shellcheck / brew install shellcheck)"
  fi
  $ok && pass "shell scripts parse (and shellcheck is clean)"
fi

# ---- 2. k8s templates -----------------------------------------------------------
if want 2; then
  if command -v envsubst >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
    tmp="$(mktemp)"
    if tools/render-templates.sh k8s/postgres/*.yaml k8s/openldap/*.yaml k8s/apps/*.yaml k8s/apps/*/*.yaml \
         k8s/tests/*.yaml k8s/_templates/new-service/*.yaml > "$tmp" 2>&1 \
       && python3 - "$tmp" <<'PY'
import sys, yaml, re
text = open(sys.argv[1]).read()
docs = [d for d in yaml.safe_load_all(text) if d]
assert docs, "no documents rendered"
for d in docs:
    assert "kind" in d and "metadata" in d and "name" in d["metadata"], f"bad document: {str(d)[:80]}"
left = sorted(set(re.findall(r"\$\{[A-Z_]+\}", text)) - {"${PLAYWRIGHT_VERSION}"})
assert not left, f"unfilled variables: {left}"
print(f"   {len(docs)} kubernetes objects rendered and parsed")
PY
    then pass "k8s templates render + parse as YAML"; else fail "k8s templates (see $tmp)"; fi
    # ENABLE_TLS=true path
    if tools/render-templates.sh --tls k8s/apps/java/ingress.yaml > "$tmp" 2>&1 && python3 -c "import yaml,sys; d=[x for x in yaml.safe_load_all(open(sys.argv[1])) if x][0]; assert d['spec']['tls'][0]['hosts'] and 'cert-manager' in str(d['metadata']['annotations'])" "$tmp"; then
      pass "ingress template with ENABLE_TLS=true"; else fail "ingress template with ENABLE_TLS=true (see $tmp)"; fi
  else
    skip "k8s templates: need envsubst + python3 with PyYAML (pip install pyyaml)"
  fi
fi

# ---- 3. realm JSON -------------------------------------------------------------
if want 3; then
  ok=true
  for f in helm/keycloak/realms/*.json k8s/keycloak/*.json; do
    sed -e 's/__[A-Z_]*__/x/g' -e 's/\${[A-Z_]*}/x/g' "$f" | python3 -m json.tool >/dev/null || { fail "invalid JSON: $f"; ok=false; }
  done
  $ok && pass "realm + LDAP JSON files are valid JSON"
fi

# ---- 4. Helm chart ---------------------------------------------------------------
if want 4; then
  if command -v helm >/dev/null; then
    if helm lint helm/keycloak >/dev/null && helm template keycloak helm/keycloak --set realm.baseDomain=1.2.3.4.nip.io >/dev/null; then
      pass "helm lint + helm template"; else fail "helm lint/template"; fi
  elif command -v go >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
    vals="$(mktemp)"; out="$(mktemp)"
    python3 - "$vals" <<'PY'
import sys, json, yaml
base = yaml.safe_load(open("helm/keycloak/values.yaml"))
override = {"hostname": "http://keycloak.1.2.3.4.nip.io", "ingress": {"host": "keycloak.1.2.3.4.nip.io"},
            "realm": {"baseDomain": "1.2.3.4.nip.io"}}
json.dump([base, override], open(sys.argv[1], "w"))
PY
    if (cd tools/dev && go run minihelm.go -chart ../../helm/keycloak -values "$vals" -release keycloak -namespace identity) > "$out" 2>/dev/null \
       && python3 - "$out" <<'PY'
import sys, yaml, json, re
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
kinds = sorted(d["kind"] for d in docs)
assert kinds == ["ConfigMap", "Deployment", "Ingress", "Secret", "Service"], kinds
cm = [d for d in docs if d["kind"] == "ConfigMap"][0]
for name, body in cm["data"].items():
    realm = json.loads(body)
    left = set(re.findall(r"__[A-Z_]+__", json.dumps(realm))) - {"__PLACEHOLDERS__"}
    assert not left, f"{name}: placeholders not replaced: {left}"
print("   chart renders 5 objects; realm JSON inside the ConfigMap is valid")
PY
    then pass "Helm chart renders (minihelm) + realm placeholders replaced"; else fail "Helm chart render (see $out)"; fi
  else
    skip "Helm chart: install helm (best) or go + PyYAML for the minihelm check"
  fi
fi

# ---- 5. Python deli --------------------------------------------------------------
if want 5; then
  if python3 -c 'import pytest, flask, authlib, jwt' 2>/dev/null; then
    if (cd apps/python-deli-app && python3 -m pytest -q tests >/tmp/pytest.out 2>&1); then
      pass "Python deli: $(tail -1 /tmp/pytest.out)"; else fail "Python deli tests (see /tmp/pytest.out)"; fi
  else
    skip "Python deli tests: pip install -r apps/python-deli-app/requirements-dev.txt"
  fi
fi

# ---- 6. Go inspector -------------------------------------------------------------
if want 6; then
  if command -v go >/dev/null; then
    if (cd tests/go-client && go vet ./... && go test ./... >/tmp/gotest.out 2>&1); then
      pass "Go inspector: go vet + go test"; else fail "Go inspector (see /tmp/gotest.out)"; fi
  else
    skip "Go inspector: install Go"
  fi
fi

# ---- 7. Playwright ---------------------------------------------------------------
if want 7; then
  if command -v npx >/dev/null; then
    if [[ ! -d tests/playwright/node_modules ]]; then
      (cd tests/playwright && npm install --no-fund --no-audit --loglevel=error >/dev/null 2>&1) || true
    fi
    if (cd tests/playwright && npx playwright test --list >/tmp/pw.out 2>&1); then
      pass "Playwright: $(grep -E '^Total' /tmp/pw.out)"; else fail "Playwright --list (see /tmp/pw.out)"; fi
  else
    skip "Playwright: install Node.js"
  fi
fi

# ---- 8. Java store ---------------------------------------------------------------
if want 8; then
  if command -v mvn >/dev/null; then
    if (cd apps/java-grocery-app && mvn -q -B -DskipTests compile >/tmp/mvn.out 2>&1); then
      pass "Java store: mvn compile"; else fail "Java store: mvn compile (see /tmp/mvn.out)"; fi
  elif python3 -c 'import javalang' 2>/dev/null; then
    if python3 - <<'PY'
import javalang, pathlib
for f in pathlib.Path("apps/java-grocery-app/src").rglob("*.java"):
    javalang.parse.parse(f.read_text())
print("   all .java files parse (syntax only; 'pip install javalang')")
PY
    then pass "Java store: syntax check (javalang)"; else fail "Java store: syntax check"; fi
  else
    skip "Java store: install Maven (mvn) for a real compile, or 'pip install javalang' for a syntax check"
  fi
fi

echo
echo "checks: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
