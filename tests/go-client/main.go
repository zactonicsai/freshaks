// The Go inspector: a small, fast program that walks through every door of both apps
// with every badge and checks that each door answers the way the store rules say.
//
// It asks Keycloak for a token the same way a mobile app would (Resource Owner Password
// grant on the public client "grocery-test-client"), then calls the APIs with
// "Authorization: Bearer <token>". Exit code 0 = all good, 1 = something is wrong.
//
// Settings come from environment variables (k8s/tests/test-config.yaml):
//
//	KEYCLOAK_URL, KC_REALM, TEST_CLIENT_ID, JAVA_URL, PYTHON_URL, DEMO_USER_PASSWORD
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Check is one row of the inspection checklist.
type Check struct {
	Name   string
	User   string // "" = no token at all
	Method string
	URL    string
	Body   string
	Want   int // expected HTTP status
}

// Config is everything the inspector needs to know.
type Config struct {
	KeycloakURL string
	Realm       string
	ClientID    string
	JavaURL     string
	PythonURL   string
	Password    string
}

func configFromEnv() (Config, error) {
	c := Config{
		KeycloakURL: strings.TrimRight(os.Getenv("KEYCLOAK_URL"), "/"),
		Realm:       os.Getenv("KC_REALM"),
		ClientID:    os.Getenv("TEST_CLIENT_ID"),
		JavaURL:     strings.TrimRight(os.Getenv("JAVA_URL"), "/"),
		PythonURL:   strings.TrimRight(os.Getenv("PYTHON_URL"), "/"),
		Password:    os.Getenv("DEMO_USER_PASSWORD"),
	}
	if c.ClientID == "" {
		c.ClientID = "grocery-test-client"
	}
	if c.Realm == "" {
		c.Realm = "grocery"
	}
	var missing []string
	for name, v := range map[string]string{"KEYCLOAK_URL": c.KeycloakURL, "JAVA_URL": c.JavaURL,
		"PYTHON_URL": c.PythonURL, "DEMO_USER_PASSWORD": c.Password} {
		if v == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return c, fmt.Errorf("missing environment variables: %s", strings.Join(missing, ", "))
	}
	return c, nil
}

// TokenFetcher asks the front office (Keycloak) for a badge (access token).
type TokenFetcher struct {
	Client *http.Client
	Cfg    Config
	cache  map[string]string
}

func (t *TokenFetcher) Token(user string) (string, error) {
	if t.cache == nil {
		t.cache = map[string]string{}
	}
	if tok, ok := t.cache[user]; ok {
		return tok, nil
	}
	form := url.Values{}
	form.Set("grant_type", "password")
	form.Set("client_id", t.Cfg.ClientID)
	form.Set("username", user)
	form.Set("password", t.Cfg.Password)
	form.Set("scope", "openid")
	endpoint := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/token", t.Cfg.KeycloakURL, t.Cfg.Realm)
	resp, err := t.Client.PostForm(endpoint, form)
	if err != nil {
		return "", fmt.Errorf("token request for %s: %w", user, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("token request for %s: HTTP %d: %s", user, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var parsed struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil || parsed.AccessToken == "" {
		return "", fmt.Errorf("token response for %s had no access_token", user)
	}
	t.cache[user] = parsed.AccessToken
	return parsed.AccessToken, nil
}

// Checklist builds the full inspection list for both apps.
func Checklist(c Config) []Check {
	j, p := c.JavaURL, c.PythonURL
	return []Check{
		// ---- Java store -------------------------------------------------------------
		{"java: no badge -> 401 on products", "", "GET", j + "/api/products", "", 401},
		{"java: public store-info needs no badge", "", "GET", j + "/api/public/store-info", "", 200},
		{"java: shopper sees products", "sam.shopper", "GET", j + "/api/products", "", 200},
		{"java: shopper sees own badge", "sam.shopper", "GET", j + "/api/me", "", 200},
		{"java: shopper places an order", "sam.shopper", "POST", j + "/api/orders", `{"items":[{"productId":1,"quantity":1}]}`, 201},
		{"java: shopper sees own receipts", "sam.shopper", "GET", j + "/api/orders/mine", "", 200},
		{"java: shopper cannot open the register", "sam.shopper", "GET", j + "/api/orders", "", 403},
		{"java: shopper cannot read reports", "sam.shopper", "GET", j + "/api/reports/sales", "", 403},
		{"java: shopper cannot add products", "sam.shopper", "POST", j + "/api/products", `{"name":"Sneaky","price":1.00,"stock":1}`, 403},
		{"java: cashier opens the register", "casey.cashier", "GET", j + "/api/orders", "", 200},
		{"java: cashier cannot read reports", "casey.cashier", "GET", j + "/api/reports/sales", "", 403},
		{"java: manager reads reports", "morgan.manager", "GET", j + "/api/reports/sales", "", 200},
		{"java: manager reads the notebook", "morgan.manager", "GET", j + "/api/activity", "", 200},
		{"java: manager also opens the register (composite group)", "morgan.manager", "GET", j + "/api/orders", "", 200},
		{"java: LDAP manager (riley) reads reports", "riley.ldap", "GET", j + "/api/reports/sales", "", 200},
		{"java: LDAP cashier (jordan) opens the register", "jordan.ldap", "GET", j + "/api/orders", "", 200},
		{"java: LDAP shopper (alex) cannot open the register", "alex.ldap", "GET", j + "/api/orders", "", 403},
		{"java: LDAP shopper (alex) still sees products", "alex.ldap", "GET", j + "/api/products", "", 200},
		// ---- Python deli ------------------------------------------------------------
		{"python: no badge -> 401 on tickets", "", "GET", p + "/api/tickets", "", 401},
		{"python: public menu needs no badge", "", "GET", p + "/api/public/menu", "", 200},
		{"python: shopper sees own badge", "sam.shopper", "GET", p + "/api/me", "", 200},
		{"python: shopper creates a ticket", "sam.shopper", "POST", p + "/api/tickets", `{"item":"Fruit cup","notes":"from the Go inspector"}`, 201},
		{"python: shopper cannot see the kitchen board", "sam.shopper", "GET", p + "/api/tickets", "", 403},
		{"python: cashier sees the kitchen board", "casey.cashier", "GET", p + "/api/tickets", "", 200},
		{"python: cashier cannot read the notebook", "casey.cashier", "GET", p + "/api/activity", "", 403},
		{"python: manager reads the notebook", "morgan.manager", "GET", p + "/api/activity", "", 200},
		{"python: LDAP cashier (jordan) sees the kitchen board", "jordan.ldap", "GET", p + "/api/tickets", "", 200},
		{"python: LDAP shopper (alex) cannot see the kitchen board", "alex.ldap", "GET", p + "/api/tickets", "", 403},
	}
}

// Run performs every check and returns how many failed.
func Run(client *http.Client, tokens *TokenFetcher, checks []Check, out io.Writer) int {
	failed := 0
	for _, c := range checks {
		var req *http.Request
		var err error
		if c.Body != "" {
			req, err = http.NewRequest(c.Method, c.URL, bytes.NewBufferString(c.Body))
			if req != nil {
				req.Header.Set("Content-Type", "application/json")
			}
		} else {
			req, err = http.NewRequest(c.Method, c.URL, nil)
		}
		if err != nil {
			fmt.Fprintf(out, "FAIL  %-60s (%v)\n", c.Name, err)
			failed++
			continue
		}
		req.Header.Set("Accept", "application/json")
		if c.User != "" {
			tok, err := tokens.Token(c.User)
			if err != nil {
				fmt.Fprintf(out, "FAIL  %-60s (%v)\n", c.Name, err)
				failed++
				continue
			}
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		resp, err := client.Do(req)
		if err != nil {
			fmt.Fprintf(out, "FAIL  %-60s (%v)\n", c.Name, err)
			failed++
			continue
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode == c.Want {
			fmt.Fprintf(out, "PASS  %-60s %s %s -> %d\n", c.Name, c.Method, c.URL, resp.StatusCode)
		} else {
			fmt.Fprintf(out, "FAIL  %-60s %s %s -> got %d, wanted %d\n", c.Name, c.Method, c.URL, resp.StatusCode, c.Want)
			failed++
		}
	}
	return failed
}

func main() {
	cfg, err := configFromEnv()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(2)
	}
	client := &http.Client{Timeout: 20 * time.Second}
	tokens := &TokenFetcher{Client: client, Cfg: cfg}
	fmt.Printf("Go inspector: keycloak=%s realm=%s java=%s python=%s\n\n", cfg.KeycloakURL, cfg.Realm, cfg.JavaURL, cfg.PythonURL)
	checks := Checklist(cfg)
	failed := Run(client, tokens, checks, os.Stdout)
	fmt.Printf("\n%d checks, %d failed\n", len(checks), failed)
	if failed > 0 {
		os.Exit(1)
	}
}
