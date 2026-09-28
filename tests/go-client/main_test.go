package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// fakeWorld pretends to be Keycloak + both apps so the inspector can be tested without a cluster.
func fakeWorld(t *testing.T) *httptest.Server {
	t.Helper()
	roles := map[string][]string{
		"sam.shopper": {"shopper"}, "casey.cashier": {"cashier"}, "morgan.manager": {"manager", "cashier"},
		"alex.ldap": {"shopper"}, "jordan.ldap": {"cashier"}, "riley.ldap": {"manager", "cashier"},
	}
	has := func(user, role string) bool {
		for _, r := range roles[user] {
			if r == role {
				return true
			}
		}
		return false
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/realms/grocery/protocol/openid-connect/token", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		user := r.Form.Get("username")
		if _, ok := roles[user]; !ok || r.Form.Get("password") != "pw" || r.Form.Get("grant_type") != "password" {
			http.Error(w, `{"error":"invalid_grant"}`, 401)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"access_token": "token-for-" + user})
	})
	userOf := func(r *http.Request) string {
		h := r.Header.Get("Authorization")
		if !strings.HasPrefix(h, "Bearer token-for-") {
			return ""
		}
		return strings.TrimPrefix(h, "Bearer token-for-")
	}
	guard := func(w http.ResponseWriter, r *http.Request, created bool, allowed ...string) {
		user := userOf(r)
		if user == "" {
			w.WriteHeader(401)
			return
		}
		if len(allowed) > 0 {
			ok := false
			for _, a := range allowed {
				if has(user, a) {
					ok = true
				}
			}
			if !ok {
				w.WriteHeader(403)
				return
			}
		}
		if created {
			w.WriteHeader(201)
		}
		w.Write([]byte("{}"))
	}
	mux.HandleFunc("/api/public/", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("{}")) })
	mux.HandleFunc("/api/products", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			guard(w, r, true, "manager")
			return
		}
		guard(w, r, false)
	})
	mux.HandleFunc("/api/me", func(w http.ResponseWriter, r *http.Request) { guard(w, r, false) })
	mux.HandleFunc("/api/orders/mine", func(w http.ResponseWriter, r *http.Request) { guard(w, r, false) })
	mux.HandleFunc("/api/orders", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			guard(w, r, true)
			return
		}
		guard(w, r, false, "cashier", "manager")
	})
	mux.HandleFunc("/api/reports/sales", func(w http.ResponseWriter, r *http.Request) { guard(w, r, false, "manager") })
	mux.HandleFunc("/api/activity", func(w http.ResponseWriter, r *http.Request) { guard(w, r, false, "manager") })
	mux.HandleFunc("/api/tickets", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			guard(w, r, true)
			return
		}
		guard(w, r, false, "cashier", "manager")
	})
	return httptest.NewServer(mux)
}

func TestChecklistPassesAgainstFakeWorld(t *testing.T) {
	srv := fakeWorld(t)
	defer srv.Close()
	cfg := Config{KeycloakURL: srv.URL, Realm: "grocery", ClientID: "grocery-test-client",
		JavaURL: srv.URL, PythonURL: srv.URL, Password: "pw"}
	var out bytes.Buffer
	checks := Checklist(cfg)
	failed := Run(srv.Client(), &TokenFetcher{Client: srv.Client(), Cfg: cfg}, checks, &out)
	if failed != 0 {
		t.Fatalf("expected 0 failures, got %d:\n%s", failed, out.String())
	}
	if !strings.Contains(out.String(), "PASS") || strings.Count(out.String(), "PASS") != len(checks) {
		t.Fatalf("expected %d PASS lines:\n%s", len(checks), out.String())
	}
}

func TestWrongPasswordIsReported(t *testing.T) {
	srv := fakeWorld(t)
	defer srv.Close()
	cfg := Config{KeycloakURL: srv.URL, Realm: "grocery", JavaURL: srv.URL, PythonURL: srv.URL, Password: "wrong"}
	var out bytes.Buffer
	failed := Run(srv.Client(), &TokenFetcher{Client: srv.Client(), Cfg: cfg}, Checklist(cfg), &out)
	if failed == 0 {
		t.Fatal("expected failures when the password is wrong")
	}
	if !strings.Contains(out.String(), "HTTP 401") {
		t.Fatalf("expected the 401 from the token endpoint to be shown:\n%s", out.String())
	}
}

func TestDetectsBrokenDoor(t *testing.T) {
	srv := fakeWorld(t)
	defer srv.Close()
	cfg := Config{KeycloakURL: srv.URL, Realm: "grocery", JavaURL: srv.URL, PythonURL: srv.URL, Password: "pw"}
	checks := []Check{{"shopper must NOT read reports", "sam.shopper", "GET", srv.URL + "/api/reports/sales", "", 200}}
	var out bytes.Buffer
	if failed := Run(srv.Client(), &TokenFetcher{Client: srv.Client(), Cfg: cfg}, checks, &out); failed != 1 {
		t.Fatalf("expected exactly 1 failure, got %d:\n%s", failed, out.String())
	}
}

func TestConfigFromEnvReportsMissing(t *testing.T) {
	for _, k := range []string{"KEYCLOAK_URL", "JAVA_URL", "PYTHON_URL", "DEMO_USER_PASSWORD"} {
		os.Unsetenv(k)
	}
	if _, err := configFromEnv(); err == nil || !strings.Contains(err.Error(), "KEYCLOAK_URL") {
		t.Fatalf("expected a helpful error about missing variables, got %v", err)
	}
	os.Setenv("KEYCLOAK_URL", "http://kc/")
	os.Setenv("JAVA_URL", "http://java/")
	os.Setenv("PYTHON_URL", "http://py")
	os.Setenv("DEMO_USER_PASSWORD", "x")
	cfg, err := configFromEnv()
	if err != nil || cfg.KeycloakURL != "http://kc" || cfg.Realm != "grocery" || cfg.ClientID != "grocery-test-client" {
		t.Fatalf("unexpected config %+v (err %v)", cfg, err)
	}
}
