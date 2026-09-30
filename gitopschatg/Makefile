.PHONY: prereqs cluster gitea repos argocd jenkins job app build status test destroy

prereqs:
	./scripts/00-prereqs.sh
cluster:
	./scripts/01-create-kind-registry.sh
gitea:
	./scripts/02-install-gitea.sh
repos:
	./scripts/03-seed-gitea-repos.sh
argocd:
	./scripts/04-install-argocd.sh
jenkins:
	./scripts/05-install-jenkins.sh
job:
	./scripts/06-create-jenkins-job.sh
app:
	./scripts/07-bootstrap-argocd-app.sh
build:
	./scripts/08-trigger-build.sh
status:
	./scripts/09-status.sh
test:
	./tests/static-verify.sh
destroy:
	./scripts/10-destroy.sh
