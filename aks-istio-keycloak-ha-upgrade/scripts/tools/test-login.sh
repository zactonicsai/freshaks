#!/usr/bin/env bash
# =============================================================================
# test-login.sh — sign in as a test user with curl and exercise everything:
# the OIDC login through Keycloak, single sign-on into the second app, the
# shared NFS volume, the admin role, the egress gateway and the logout.
# Usage: ./scripts/tools/test-login.sh [USER]     (alice, bob or carol; default alice)
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# The public address must be known.
require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"
# The host names must be known.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
# The password of the test users must exist.
[[ -n "${TEST_USER_PASSWORD:-}" ]] || fail "No test password yet. Run scripts/install/18-create-secrets.sh first."

# Test user: first argument, or alice (who also has the admin role).
user="${1:-alice}"
# Short names for the two application addresses.
app1="https://app1.${BASE_DOMAIN}"
# Second application.
app2="https://app2.${BASE_DOMAIN}"

# A private file that plays the role of the browser's cookie store.
jar="$(mktemp "${STATE_DIR}/cookies.XXXXXX")"
# Delete it when the script ends (it holds session cookies).
cleanup_add "${jar}"

# Announce the step.
step "1/7 Open the login page: app1 sends the browser to Keycloak"
# --location follows the redirect to Keycloak; the cookie options read and
# write the cookie file. The result is the HTML of the Keycloak login page.
login_page="$(curl_mesh --location --cookie "${jar}" --cookie-jar "${jar}" "${app1}/oauth2/authorization/keycloak")"
# Cut the address out of <form ... action="...">, then turn "&amp;" back into "&".
form_action="$(printf '%s' "${login_page}" | sed -n 's/.*action="\([^"]*login-actions\/authenticate[^"]*\)".*/\1/p' | head -n 1 | sed 's/&amp;/\&/g')"
# Without a form there is nothing to post to.
[[ -n "${form_action}" ]] || fail "Keycloak did not show a login form. Check 'kubectl -n keycloak get pods' and the smoke test."
# Report success.
ok "Keycloak login form received"

# Announce the step.
step "2/7 Send user name and password to Keycloak"
# The password is piped in ("password@-" reads it from standard input), so it
# never appears on a command line or in the log. After the login Keycloak
# redirects to app1 with a one-time code; app1 swaps the code for tokens
# (a pod-to-pod call inside the mesh) and creates its own session.
code="$(printf '%s' "${TEST_USER_PASSWORD}" | curl_mesh --location --cookie "${jar}" --cookie-jar "${jar}" --output /dev/null --write-out '%{http_code}' --data-urlencode "username=${user}" --data-urlencode "password@-" --data-urlencode "credentialId=" "${form_action}")"
# The chain of redirects must end on the start page of app1.
[[ "${code}" == "200" ]] || fail "Login as ${user} failed (HTTP ${code})."
# Report success.
ok "signed in as ${user}"

# Announce the step.
step "3/7 Call the protected API of app1"
# /api/me returns the user name and the roles from the ID token.
me1="$(curl_mesh --cookie "${jar}" --cookie-jar "${jar}" "${app1}/api/me")"
# Show the answer.
info "app1 /api/me: ${me1}"
# The answer must contain the user name.
printf '%s' "${me1}" | grep -q "\"username\":\"${user}\"" || fail "app1 did not return the signed-in user."
# Only alice has the role "admin": she gets 200, everybody else 403.
if [[ "${user}" == "alice" ]]; then admin_code=200; else admin_code=403; fi
# Call the admin-only endpoint.
expect_code "app1 admin API for ${user}" "${admin_code}" --cookie "${jar}" "${app1}/api/admin"

# Announce the step.
step "4/7 Single sign-on: open app2 without typing the password again"
# app2 redirects to Keycloak; Keycloak recognises its session cookie and
# sends the browser straight back, signed in.
code="$(curl_mesh --location --cookie "${jar}" --cookie-jar "${jar}" --output /dev/null --write-out '%{http_code}' "${app2}/oauth2/authorization/keycloak")"
# The chain of redirects must end on the start page of app2.
[[ "${code}" == "200" ]] || fail "Single sign-on into app2 failed (HTTP ${code})."
# Ask app2 who we are.
me2="$(curl_mesh --cookie "${jar}" --cookie-jar "${jar}" "${app2}/api/me")"
# Show the answer.
info "app2 /api/me: ${me2}"
# The answer must contain the same user name.
printf '%s' "${me2}" | grep -q "\"username\":\"${user}\"" || fail "app2 did not return the signed-in user."
# Report success.
ok "single sign-on works"

# Announce the step.
step "5/7 Shared NFS volume: write a note through app1, read it through app2"
# Requests that change data need the anti-forgery (CSRF) token. The app sends
# it as cookie XSRF-TOKEN; column 6 of the cookie file is the name, column 7
# the value.
csrf="$(awk -v host="app1.${BASE_DOMAIN}" '$1 == host && $6 == "XSRF-TOKEN" { value = $7 } END { print value }' "${jar}")"
# A unique text, so we can find exactly this note again.
note="login test by ${user} at $(date '+%H:%M:%S')"
# POST the note as JSON; the token goes into the X-XSRF-TOKEN header.
code="$(curl_mesh --cookie "${jar}" --cookie-jar "${jar}" --output /dev/null --write-out '%{http_code}' --header "Content-Type: application/json" --header "X-XSRF-TOKEN: ${csrf}" --data "{\"text\":\"${note}\"}" "${app1}/api/notes")"
# 201 = created.
[[ "${code}" == "201" ]] || fail "Saving a note through app1 failed (HTTP ${code})."
# The note must be visible through the other application.
curl_mesh --cookie "${jar}" "${app2}/api/notes" | grep -q "${note}" || fail "app2 cannot see the note that app1 saved on the shared volume."
# Report success.
ok "note written by app1 is visible in app2"

# Announce the step.
step "6/7 Egress: the allowed host works, every other host is blocked"
# The app calls ${EGRESS_TEST_HOST}; the call leaves through the egress gateway.
allowed="$(curl_mesh --cookie "${jar}" "${app1}/api/egress")"
# Show the answer (for api.ipify.org: the public IP the cluster uses for outgoing traffic).
info "allowed call: ${allowed}"
# The app must report that the host was reachable.
printf '%s' "${allowed}" | grep -q '"reachable":true' || fail "The allowed egress host could not be reached."
# The app calls ${EGRESS_BLOCKED_HOST}, which the mesh does not know.
blocked="$(curl_mesh --cookie "${jar}" "${app1}/api/egress/blocked")"
# Show the answer.
info "blocked call: ${blocked}"
# The app must report that the host was NOT reachable.
printf '%s' "${blocked}" | grep -q '"reachable":false' || fail "A host that is not on the allow list was reachable."
# Report success.
ok "egress rules work"

# Announce the step.
step "7/7 Sign out of app1 (and with it out of Keycloak)"
# The logout must be a POST with the CSRF token. app1 ends its session and
# redirects to Keycloak's logout page, which redirects back to app1.
code="$(curl_mesh --location --cookie "${jar}" --cookie-jar "${jar}" --output /dev/null --write-out '%{http_code}' --header "X-XSRF-TOKEN: ${csrf}" --data "" "${app1}/logout")"
# The chain of redirects must end on the public start page.
[[ "${code}" == "200" ]] || fail "Logout failed (HTTP ${code})."
# The API must refuse us again.
expect_code "app1 API after logout" 401 --cookie "${jar}" "${app1}/api/me"
# Final message.
ok "login test passed for user ${user}"
