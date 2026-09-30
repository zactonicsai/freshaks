# Official references

These are the main upstream references used by the lab.

- Kind local registry: https://kind.sigs.k8s.io/docs/user/local-registry/
- Argo CD installation: https://argo-cd.readthedocs.io/en/latest/operator-manual/installation/
- Argo CD Helm/GitOps behavior: https://argo-cd.readthedocs.io/en/latest/user-guide/helm/
- Jenkins on Kubernetes with Helm: https://www.jenkins.io/doc/book/installing/kubernetes/
- Jenkins Helm charts: https://charts.jenkins.io/
- Gitea Docker installation: https://docs.gitea.com/installation/install-with-docker-rootless/
- Atlassian Bitbucket pricing: https://www.atlassian.com/software/bitbucket/pricing
- Atlassian Bitbucket Data Center license expiration behavior: https://support.atlassian.com/bitbucket-data-center/kb/what-happens-when-a-bitbucket-data-center-license-expires/

## Bitbucket note for this lab

Bitbucket Cloud has a free plan for small teams, but the self-managed Bitbucket Data Center product is licensed software. For a disposable local self-hosted lab, Gitea is simpler because it is free and open source. If you already have an appropriate Bitbucket instance, the Jenkins/Argo design does not change; only Git URLs and credentials change.
