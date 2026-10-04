# =============================================================================
# docker/tools/Dockerfile — a small image with the command-line tools the
# scripts need: kubectl, helm, curl, openssl and bash. Because the tools run
# in this container, the only program you must install yourself is Docker.
# Built by "docker compose build tools" (scripts/install/02-start-cluster.sh).
# =============================================================================

# Small base image; a fixed version keeps builds repeatable.
FROM alpine:3.22

# Versions come from config/versions.env via docker-compose.yml.
ARG KUBECTL_VERSION
ARG HELM_VERSION

# bash: for scripts started inside the container. curl: tests and downloads.
# openssl: creates the TLS certificate. ca-certificates: lets curl trust https sites.
# hadolint ignore=DL3018
RUN apk add --no-cache bash ca-certificates curl openssl

# Stop a build step when any command in it fails, also inside a pipe ("a | b").
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Downloads are unpacked in /tmp.
WORKDIR /tmp

# Download kubectl and helm for the CPU type of this machine (Intel/AMD or ARM,
# for example Apple Silicon) and check each download against its published
# checksum before installing it. The last two lines create a home folder that
# any user id may write to: the container runs with YOUR user id (see
# docker-compose.yml), which has no home folder in this image.
RUN set -ux; \
    case "$(apk --print-arch)" in \
      x86_64) arch=amd64 ;; \
      aarch64) arch=arm64 ;; \
      *) echo "unsupported CPU type: $(apk --print-arch)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"; \
    curl -fsSL -o kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl.sha256"; \
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -; \
    install -m 0755 kubectl /usr/local/bin/kubectl; \
    curl -fsSL -o helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz"; \
    curl -fsSL -o helm.sha256 "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz.sha256"; \
    echo "$(cat helm.sha256)  helm.tar.gz" | sha256sum -c -; \
    tar -xzf helm.tar.gz; \
    install -m 0755 "linux-${arch}/helm" /usr/local/bin/helm; \
    rm -rf kubectl kubectl.sha256 helm.tar.gz helm.sha256 "linux-${arch}"; \
    mkdir -p /tmp/home; \
    chmod 1777 /tmp/home

# The project folder is mounted here.
WORKDIR /work

# Do nothing; the scripts start commands with "docker exec".
CMD ["tail", "-f", "/dev/null"]
