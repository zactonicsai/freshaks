"""k8s-doctor package.

The package intentionally calls the installed ``kubectl`` and ``helm`` binaries
rather than embedding Kubernetes client libraries. This keeps the tool aligned
with the credentials, plugins, kubeconfig, and Helm setup already on the host.
"""

__version__ = "0.1.0"
