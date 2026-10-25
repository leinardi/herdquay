# Docker access

HerdQuay ships the Docker CLI with buildx and Compose, and by default **no Docker API at all**: no
daemon in the container, no socket mount, `DOCKER_HOST` unset. The one supported way to give it a
daemon is a **dedicated rootless daemon** next to it ([section 3](#3-a-dedicated-rootless-daemon)),
an opt-in of the deployment. `herdquay doctor` checks the daemon the CLI reaches (`DOCKER_HOST`, or
the current Docker context):

| The CLI reaches | Doctor |
| --- | --- |
| no daemon configured | ok |
| a daemon that reports `rootless` | ok |
| a daemon that does not report `rootless` (the host's, behind whatever path) | FAIL |
| a configured daemon that does not answer | FAIL |
| anything, while `/var/run/docker.sock` exists | FAIL |

## 1. Read-only diagnostics (designed, not wired)

Goal: let Claude read the state of the host's containers and services while debugging, never
change it. The usual tool is a Docker socket proxy in front of the daemon, and a GET-only proxy
is less read-only than it looks:

- **Tecnativa's docker-socket-proxy has no `LOGS` switch.** Its `haproxy.cfg` gates paths by
  section, so `CONTAINERS=1` allows every path under `/containers`, including
  `GET /containers/{id}/logs` and `GET /containers/{id}/json`, which shows a container's
  environment variables. `SERVICES=1` does the same for `/services/{id}/logs` and service specs.
  Setting `LOGS=0` changes nothing.
- A GET-only API therefore still exposes logs, environment variables (secrets passed that way
  included), labels, mount paths, service configurations and network topology.
- A proxy network that other services already share gives HerdQuay that whole surface, and
  everything those services can reach.

Recommended design:

1. A **dedicated proxy instance** for HerdQuay, on its own internal network that only HerdQuay
   and that proxy join.
2. Only the endpoints the diagnostics need, decided explicitly: `PING`, `VERSION`, `INFO`,
   `SERVICES`, `TASKS`, `NODES`, and `CONTAINERS` only if container inspection or logs are wanted
   (accepting that it includes `/json` and `/logs`). `POST=0`, and everything else off.
3. Opt-in in HerdQuay: `DOCKER_HOST=tcp://<proxy-service>:2375`. Nothing in the image changes.
4. Before enabling it, check that no service passes secrets through environment variables or
   labels, since the proxy would show them.

The proxy fronts the host's daemon, which is not rootless, so `herdquay doctor` fails it as it
stands: wiring this design up includes giving the doctor a way to tell the proxy apart.

**Never** connect HerdQuay to a read-write proxy, and never fall back to one if the read-only
proxy lacks an endpoint.

## 2. Docker CLI and Compose without an API

Always available: `docker`, `docker buildx`, `docker compose` for reading, linting and rendering
(`docker compose config`, `docker buildx bake --print`), and the projects' make targets that only
need the CLI to exist.

## 3. A dedicated rootless daemon

Builds, `docker run`, Compose and image tests need a daemon. HerdQuay gets one of its own: a
rootless `dockerd` in a separate container next to it, with its own data root, and no access to the
host's daemon, containers, images or volumes. What the agent breaks there (a
`docker system prune -af --volumes` included) stays there.

**One daemon per consumer.** Never share one between HerdQuay and anything else (a CI runner, a
second environment): each could then see, exec into and delete the other's containers and volumes,
and without per-container cgroups (below) one could starve the other.

### What HerdQuay needs from it

- `DOCKER_HOST` set to the daemon: a Unix socket on a volume shared with HerdQuay only
  (`unix:///<path>/docker.sock`), or TCP with TLS. Never at `/var/run/docker.sock`.
- The socket readable and writable by UID 568.
- The daemon reports `rootless` in `docker info` (the doctor checks it).
- HerdQuay's workspace mounted in the daemon's container **at the same path**,
  `/home/herdquay/workspace`, so `docker run -v "$PWD:/src"` and Compose bind mounts find the files.
- The daemon's rootless user is UID 568 too, so files that containers write into bind mounts come
  back owned by 568. The upstream image's rootless user is 1000: with it, those files are not
  HerdQuay's.

### Running it

Verified on 2026-10-25 on a TrueNAS host (kernel 6.12), Docker 29.9.2: the upstream
`docker:dind-rootless` image (pinned by digest) runs **without `--privileged` and without any added
capability**, with:

```text
--security-opt seccomp=unconfined     # unshare and mount, for the user namespace and overlayfs
--security-opt apparmor=unconfined    # mounts inside the container
--security-opt systempaths=unconfined # an unmasked /proc for the inner containers
--device /dev/net/tun                 # slirp4netns's tap device; without it the daemon exits
```

It uses the native `overlayfs` storage driver (no vfs or fuse-overlayfs). It needs unprivileged
user namespaces on the host. Docker Swarm ignores `security_opt`, so it runs as a plain container
(Compose, a NAS app), on the same node as HerdQuay. Besides its socket it listens on TCP 2376 with
TLS by default. Cap its CPU and memory on its container, and its data root with a quota: those are
the only limits that take effect (below).

### Limits

- **No per-container cgroups.** Without systemd, rootless mode runs with `Cgroup Driver: none`:
  `docker run --memory` and `--cpus` are ignored, and a container's `/sys/fs/cgroup` shows the whole
  daemon's usage (`memory.peak` included). Tests that measure a container's own cgroup cannot run
  here.
- **Published ports live in the daemon's container**: `docker run -p 8080:80` answers at the
  daemon's address on a network it shares with HerdQuay, not at HerdQuay's `localhost`.
- **No privileged containers**, so no Docker-in-Docker inside it (runhold's DinD tests,
  `services: docker:dind`), no BPF, no host namespaces.
- **No kernel modules**: a container can load none. What the tests need (for example `ifb`,
  `sch_netem`) must be loaded on the host.
- **Network**: its containers have the daemon's network reach, the LAN included unless the
  deployment limits its egress.

### What it still risks

Unconfined seccomp and user namespaces expose more of the kernel to the daemon's containers than
HerdQuay's own container does. Escaping still takes a kernel exploit, and lands as the daemon's
unprivileged user, not as root: with the host's socket, the API alone is root on the host. Keep the
host's kernel up to date.

### Never

The host's socket, a read-write proxy to the host's daemon, or a privileged Docker-in-Docker
container on the host. Each is administrative control of the host and everything it runs. A
daemon on another machine is a stronger boundary than the rootless one; the doctor accepts it too
if it runs rootless.
