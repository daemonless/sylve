#!/bin/sh
# Wraps the base /init so the image can hand you its deployment materials
# instead of booting Sylve:
#   podman run --rm -v "$PWD:/out" <image> init [--force]  -> write compose.yaml + .env
#   podman run <image> host-setup   -> print self-contained host-prep script
#   podman run <image> compose      -> print compose.yaml
#   podman run <image> env          -> print .env template
# Any other invocation boots Sylve via /init.
case "${1:-}" in
	init)       shift; exec /usr/local/share/sylve/host/sylve-init.sh "$@" ;;
	host-setup) exec cat /usr/local/share/sylve/host/host-setup.sh ;;
	compose)    exec cat /usr/local/share/sylve/compose.yaml ;;
	env)        exec cat /usr/local/share/sylve/host/sylve.env ;;
esac
exec /init "$@"
