// minihelm — a tiny stand-in for "helm template" used by tools/local-check.sh so the
// Keycloak chart can be rendered and checked on a laptop (or CI box) that has no helm.
//
// It understands the handful of Helm/Sprig functions this chart uses (include, toYaml,
// nindent, indent, quote, default, sha256sum, replace, base, ...). It is NOT a Helm
// replacement: use the real helm for deployments. Values come in as JSON (converted
// from values.yaml by local-check.sh with Python) because Go has no YAML parser built in.
//
//	go run minihelm.go -chart ../../helm/keycloak -values /tmp/values.json [-release keycloak] [-namespace identity]
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"text/template"
)

// Files mimics Helm's .Files object.
type Files struct {
	root string
}

// Glob returns path -> content for files matching a chart-relative pattern (sorted by key when ranged).
func (f Files) Glob(pattern string) map[string][]byte {
	out := map[string][]byte{}
	matches, _ := filepath.Glob(filepath.Join(f.root, pattern))
	for _, m := range matches {
		rel, _ := filepath.Rel(f.root, m)
		data, err := os.ReadFile(m)
		if err == nil {
			out[filepath.ToSlash(rel)] = data
		}
	}
	return out
}

// Get returns a chart-relative file as a string.
func (f Files) Get(name string) string {
	data, err := os.ReadFile(filepath.Join(f.root, name))
	if err != nil {
		return ""
	}
	return string(data)
}

func toYAML(v interface{}) string {
	var b strings.Builder
	writeYAML(&b, v, 0)
	return strings.TrimRight(b.String(), "\n")
}

func yamlScalar(v interface{}) string {
	switch x := v.(type) {
	case nil:
		return "null"
	case string:
		return strconv.Quote(x)
	case bool:
		return strconv.FormatBool(x)
	case float64:
		if x == float64(int64(x)) {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'f', -1, 64)
	default:
		return fmt.Sprintf("%v", x)
	}
}

func writeYAML(b *strings.Builder, v interface{}, indent int) {
	pad := strings.Repeat(" ", indent)
	switch x := v.(type) {
	case map[string]interface{}:
		if len(x) == 0 {
			b.WriteString(pad + "{}\n")
			return
		}
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			switch child := x[k].(type) {
			case map[string]interface{}:
				if len(child) == 0 {
					b.WriteString(pad + k + ": {}\n")
				} else {
					b.WriteString(pad + k + ":\n")
					writeYAML(b, child, indent+2)
				}
			case []interface{}:
				if len(child) == 0 {
					b.WriteString(pad + k + ": []\n")
				} else {
					b.WriteString(pad + k + ":\n")
					writeYAML(b, child, indent)
				}
			default:
				b.WriteString(pad + k + ": " + yamlScalar(child) + "\n")
			}
		}
	case []interface{}:
		if len(x) == 0 {
			b.WriteString(pad + "[]\n")
			return
		}
		for _, item := range x {
			switch child := item.(type) {
			case map[string]interface{}, []interface{}:
				var inner strings.Builder
				writeYAML(&inner, child, indent+2)
				s := inner.String()
				// first line goes after "- ", the rest keep their indentation
				b.WriteString(pad + "- " + strings.TrimLeft(strings.SplitN(s, "\n", 2)[0], " ") + "\n")
				if rest := strings.SplitN(s, "\n", 2); len(rest) > 1 {
					b.WriteString(rest[1])
				}
			default:
				b.WriteString(pad + "- " + yamlScalar(child) + "\n")
			}
		}
	default:
		b.WriteString(pad + yamlScalar(x) + "\n")
	}
}

func isEmpty(v interface{}) bool {
	switch x := v.(type) {
	case nil:
		return true
	case string:
		return x == ""
	case bool:
		return !x
	case float64:
		return x == 0
	case int:
		return x == 0
	case map[string]interface{}:
		return len(x) == 0
	case []interface{}:
		return len(x) == 0
	}
	return false
}

func deepMerge(dst, src map[string]interface{}) map[string]interface{} {
	for k, v := range src {
		if sv, ok := v.(map[string]interface{}); ok {
			if dv, ok := dst[k].(map[string]interface{}); ok {
				dst[k] = deepMerge(dv, sv)
				continue
			}
		}
		dst[k] = v
	}
	return dst
}

func main() {
	chart := flag.String("chart", ".", "chart directory")
	valuesJSON := flag.String("values", "", "values as JSON (base values.yaml first, overrides merged)")
	release := flag.String("release", "keycloak", "release name")
	namespace := flag.String("namespace", "identity", "namespace")
	flag.Parse()

	values := map[string]interface{}{}
	if *valuesJSON != "" {
		raw, err := os.ReadFile(*valuesJSON)
		if err != nil {
			fatal(err)
		}
		var layers []map[string]interface{}
		if err := json.Unmarshal(raw, &layers); err != nil {
			var single map[string]interface{}
			if err2 := json.Unmarshal(raw, &single); err2 != nil {
				fatal(fmt.Errorf("values file must be a JSON object or a list of objects: %v", err))
			}
			layers = []map[string]interface{}{single}
		}
		for _, l := range layers {
			values = deepMerge(values, l)
		}
	}

	chartMeta := map[string]interface{}{}
	if raw, err := os.ReadFile(filepath.Join(*chart, "Chart.yaml")); err == nil {
		for _, line := range strings.Split(string(raw), "\n") {
			if i := strings.Index(line, ":"); i > 0 && !strings.HasPrefix(line, " ") {
				chartMeta[strings.TrimSpace(line[:i])] = strings.Trim(strings.TrimSpace(line[i+1:]), `"`)
			}
		}
	}
	chartName, _ := chartMeta["name"].(string)
	if chartName == "" {
		chartName = filepath.Base(*chart)
	}

	var root *template.Template
	var funcs template.FuncMap
	funcs = template.FuncMap{
		"include": func(name string, data interface{}) (string, error) {
			var buf bytes.Buffer
			if err := root.ExecuteTemplate(&buf, name, data); err != nil {
				return "", err
			}
			return buf.String(), nil
		},
		"toYaml": toYAML,
		"quote":  func(v interface{}) string { return strconv.Quote(fmt.Sprintf("%v", v)) },
		"squote": func(v interface{}) string { return "'" + fmt.Sprintf("%v", v) + "'" },
		"indent": func(n int, s string) string {
			p := strings.Repeat(" ", n)
			return p + strings.ReplaceAll(s, "\n", "\n"+p)
		},
		"nindent": func(n int, s string) string {
			p := strings.Repeat(" ", n)
			return "\n" + p + strings.ReplaceAll(s, "\n", "\n"+p)
		},
		"default": func(d, v interface{}) interface{} {
			if isEmpty(v) {
				return d
			}
			return v
		},
		"empty":      isEmpty,
		"sha256sum":  func(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) },
		"replace":    func(old, new, s string) string { return strings.ReplaceAll(s, old, new) },
		"base":       filepath.Base,
		"upper":      strings.ToUpper,
		"lower":      strings.ToLower,
		"trimPrefix": func(p, s string) string { return strings.TrimPrefix(s, p) },
		"trimSuffix": func(p, s string) string { return strings.TrimSuffix(s, p) },
		"hasPrefix":  func(p, s string) bool { return strings.HasPrefix(s, p) },
		"contains":   func(sub, s string) bool { return strings.Contains(s, sub) },
		"trunc": func(n int, s string) string {
			if len(s) > n {
				return s[:n]
			}
			return s
		},
		"join": func(sep string, v []interface{}) string {
			parts := []string{}
			for _, x := range v {
				parts = append(parts, fmt.Sprintf("%v", x))
			}
			return strings.Join(parts, sep)
		},
		"list":     func(v ...interface{}) []interface{} { return v },
		"toString": func(v interface{}) string { return fmt.Sprintf("%v", v) },
		"int":      func(v interface{}) int { f, _ := strconv.ParseFloat(fmt.Sprintf("%v", v), 64); return int(f) },
		"b64enc":   func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) },
		"required": func(msg string, v interface{}) (interface{}, error) {
			if isEmpty(v) {
				return nil, fmt.Errorf("%s", msg)
			}
			return v, nil
		},
		"ternary": func(a, b interface{}, c bool) interface{} {
			if c {
				return a
			}
			return b
		},
		"tpl": func(s string, data interface{}) (string, error) {
			t, err := template.New("tpl").Funcs(funcs).Parse(s)
			if err != nil {
				return "", err
			}
			var buf bytes.Buffer
			err = t.Execute(&buf, data)
			return buf.String(), err
		},
	}
	root = template.New("root").Funcs(funcs)

	tplDir := filepath.Join(*chart, "templates")
	entries, err := os.ReadDir(tplDir)
	if err != nil {
		fatal(err)
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)
	for _, f := range files {
		content, err := os.ReadFile(filepath.Join(tplDir, f))
		if err != nil {
			fatal(err)
		}
		name := chartName + "/templates/" + f
		if _, err := root.New(name).Parse(string(content)); err != nil {
			fatal(fmt.Errorf("parse %s: %v", f, err))
		}
	}

	data := map[string]interface{}{
		"Values":       values,
		"Release":      map[string]interface{}{"Name": *release, "Namespace": *namespace, "Service": "Helm", "IsInstall": true, "IsUpgrade": false},
		"Chart":        map[string]interface{}{"Name": chartName, "Version": chartMeta["version"], "AppVersion": chartMeta["appVersion"]},
		"Template":     map[string]interface{}{"BasePath": chartName + "/templates"},
		"Files":        Files{root: *chart},
		"Capabilities": map[string]interface{}{"KubeVersion": map[string]interface{}{"Version": "v1.31.0"}},
	}

	failed := false
	for _, f := range files {
		if strings.HasPrefix(f, "_") || f == "NOTES.txt" {
			continue
		}
		var buf bytes.Buffer
		if err := root.ExecuteTemplate(&buf, chartName+"/templates/"+f, data); err != nil {
			fmt.Fprintf(os.Stderr, "render %s: %v\n", f, err)
			failed = true
			continue
		}
		out := strings.TrimSpace(buf.String())
		if out == "" {
			continue
		}
		fmt.Printf("---\n# Source: %s/templates/%s\n%s\n", chartName, f, out)
	}
	if notes := chartName + "/templates/NOTES.txt"; root.Lookup(notes) != nil {
		var buf bytes.Buffer
		if err := root.ExecuteTemplate(&buf, notes, data); err != nil {
			fmt.Fprintf(os.Stderr, "render NOTES.txt: %v\n", err)
			failed = true
		} else {
			fmt.Fprintf(os.Stderr, "NOTES:\n%s\n", buf.String())
		}
	}
	if failed {
		os.Exit(1)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "minihelm:", err)
	os.Exit(1)
}
