"""Allow ``python -m k8s_doctor`` to run the CLI."""

from .cli import main

raise SystemExit(main())
