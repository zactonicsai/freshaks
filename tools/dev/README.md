# tools/dev — helpers for offline checks

`minihelm.go` is a ~300-line stand-in for `helm template`, used only by `tools/local-check.sh` when the real
`helm` is not installed. It supports the handful of template functions the Keycloak chart uses (`include`, `toYaml`,
`nindent`, `quote`, `default`, `sha256sum`, `replace`, `.Files.Glob/Get`, ...). It is a learning aid and a CI
convenience — **always use real Helm for deployments.**

```bash
python3 -c 'import json,yaml; json.dump([yaml.safe_load(open("helm/keycloak/values.yaml")), {"realm":{"baseDomain":"1.2.3.4.nip.io"}}], open("/tmp/v.json","w"))'
(cd tools/dev && go run minihelm.go -chart ../../helm/keycloak -values /tmp/v.json) | less
```
