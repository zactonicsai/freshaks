# demo-app

A deliberately tiny Java 21 HTTP service used by the local GitOps lab.

- Gradle compiles/tests it.
- Jib creates the OCI image without a Docker daemon inside Jenkins.
- Jenkins pushes to the local registry.
- Jenkins changes the GitOps repository's Kustomize `newTag` only.
- Argo CD deploys the resulting desired state.

Endpoints:

- `/` returns a small JSON greeting.
- `/health` returns `{"status":"UP"}`.
