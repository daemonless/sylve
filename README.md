# Sylve

[![Build Status](https://img.shields.io/github/actions/workflow/status/daemonless/sylve/build.yaml?style=flat-square&label=Build&color=green)](https://github.com/daemonless/sylve/actions)
[![Last Commit](https://img.shields.io/github/last-commit/daemonless/sylve?style=flat-square&label=Last+Commit&color=blue)](https://github.com/daemonless/sylve/commits)

Modern, open-source management platform for FreeBSD managing Virtual Machines (Bhyve), Jails, and ZFS storage.

## Version Tags

Both tags ship Sylve's prebuilt native-FreeBSD binary from a GitHub release; they differ only in which release they track.

| Tag | Description | Best For |
| :--- | :--- | :--- |
| `latest` | The latest tagged release ([AlchemillaHQ/Sylve](https://github.com/AlchemillaHQ/Sylve)). | Most deployments. |
| `nightly` | The rolling `tip` release, tracking upstream `master`. | Early access to unreleased fixes. |

## Why Sylve is different

Sylve *manages* the host's Bhyve VMs, jails, and ZFS -- from inside its own jail. That needs host-level access a normal container doesn't get: kernel modules the jail can't load, a devfs ruleset exposing `/dev/pf`, `/dev/vmm`, and `/dev/cam/ctl`, ZFS delegation (`zfs jail`), and `allow.vmm`. `ocijail` can't express all of that through annotations, so this image ships:

- a one-time **`host-setup`** script (kernel modules, devfs ruleset, ZFS dataset), and
- an **OCI `createRuntime` hook** that delegates the ZFS pool and sets jail params on every start.

> There is **no AppJail deployment** -- the mechanism relies on Podman's OCI hooks, which AppJail doesn't have. Deploy it with Podman Compose as below.

## Requirements

- FreeBSD 15+ with `podman`, `ocijail`, and `podman-compose`
- A ZFS pool (`host-setup` creates a `sylve` dataset inside it)
- `root`

## Deploy

### 1. Prepare the host (one time)

Generate the setup script, review it, then run it. It confirms each step (`-y` to skip the prompts) and skips anything already configured.

```bash
podman run --rm ghcr.io/daemonless/sylve:latest host-setup > sylve-setup.sh
less sylve-setup.sh          # review exactly what it will change
sh sylve-setup.sh            # or: sh sylve-setup.sh -y
```

It loads the kernel modules, adds a devfs ruleset, creates the ZFS dataset, and installs the OCI hook. If it reports that `kern.racct` needs a reboot, reboot before continuing (Sylve requires it).

### 2. Create the deployment files

`init` writes `compose.yaml` and `.env` into the current directory (it refuses to overwrite existing files without `--force`):

```bash
podman run --rm -v "$PWD:/out" ghcr.io/daemonless/sylve:latest init
```

Edit `.env`:

| Variable | Set to |
| :--- | :--- |
| `SYLVE_HOSTNAME` | The hostname/FQDN you reach Sylve at -- **must match** (node-identity check). |
| `SYLVE_DATA_LOCATION` | Host path for Sylve's data. |
| `SYLVE_DATASET` | ZFS dataset to delegate (the one `host-setup` created). |

### 3. Start

```bash
mkdir -p "$SYLVE_DATA_LOCATION"   # FreeBSD won't auto-create a bind-mount source
podman compose up -d
```

Sylve is then reachable at `https://<SYLVE_HOSTNAME>:8181`.

## Notes

**Hostname must match.** Sylve's `EnsureCorrectHost` check compares its configured hostname against what you reach it at; a mismatch fails requests with `selected_node_not_found`.

**Never bind-mount `/dev` (`-v /dev:/dev`).** A nullfs `/dev` makes Bhyve guest-memory `mmap` fail with `ENXIO` (`Unable to setup memory (6)`) -- VM creation succeeds but the guest never boots. The hook mounts a real devfs via the ruleset; don't override it.

**Undo.** `sh sylve-setup.sh --undo` removes Sylve's hook and devfs ruleset. It never touches your ZFS dataset (it prints the `zfs destroy` command if you want it gone).

---

| | |
| :--- | :--- |
| **Registry** | `ghcr.io/daemonless/sylve` |
| **Upstream** | [https://github.com/AlchemillaHQ/Sylve](https://github.com/AlchemillaHQ/Sylve) |
| **Website** | [https://sylve.io](https://sylve.io) |