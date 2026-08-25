#!/bin/sh
# Writes compose.yaml + .env into a mounted directory:
#   podman run --rm -v "$PWD:/out" ghcr.io/daemonless/sylve:nightly init [--force]
# Refuses to clobber existing files unless --force.
set -eu

OUT=/out
if [ ! -d "$OUT" ]; then
	echo "sylve init: no target dir mounted. Run it like:" >&2
	echo '  podman run --rm -v "$PWD:/out" ghcr.io/daemonless/sylve:nightly init' >&2
	exit 1
fi

force=0
case "${1:-}" in
	-f|--force) force=1 ;;
	"") ;;
	*) echo "sylve init: unknown option '$1' (only --force)" >&2; exit 1 ;;
esac

ex=""
[ -e "$OUT/compose.yaml" ] && ex="$ex compose.yaml"
[ -e "$OUT/.env" ] && ex="$ex .env"
if [ -n "$ex" ] && [ "$force" -eq 0 ]; then
	echo "sylve init: refusing to overwrite:$ex" >&2
	echo "            re-run with --force to replace them." >&2
	exit 1
fi

cp /usr/local/share/sylve/compose.yaml "$OUT/compose.yaml"
cp /usr/local/share/sylve/host/sylve.env "$OUT/.env"
echo "sylve init: wrote compose.yaml and .env." >&2
echo "            edit .env, then: podman compose up -d" >&2
