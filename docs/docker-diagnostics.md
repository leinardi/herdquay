# Docker access

HerdQuay ships the Docker CLI with buildx and Compose, and **no Docker API at all**: no daemon in
the container, no socket mount, `DOCKER_HOST` unset. `herdquay doctor` fails if
`/var/run/docker.sock` ever appears and warns when `DOCKER_HOST` is set. Three separate needs,
three separate decisions, none of them taken in this phase.

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

**Never** connect HerdQuay to a read-write proxy, and never fall back to one if the read-only
proxy lacks an endpoint.

## 2. Docker CLI and Compose without an API

Already available: `docker`, `docker buildx`, `docker compose` for reading, linting and
rendering (`docker compose config`, `docker buildx bake --print`), and the projects' make targets
that only need the CLI to exist.

## 3. Builds, containers, integration tests (needs a daemon)

The read-only proxy cannot do any of this (`BUILD=0`, `POST=0`). These workflows stay outside
HerdQuay today and run in CI or on the desktop ([dev-environment.md](dev-environment.md)):
`docker-build` in four projects, image and integration tests, runhold's privileged DinD tests, the
bitgauge network harness.

If they are wanted inside HerdQuay later, the options, in order of isolation:

- **A remote builder off the host** (a dedicated VM or machine running a rootless BuildKit or
  Docker daemon, reached over TLS): no new privilege on the host. The best fit.
- **A rootless sibling daemon** for HerdQuay alone (as rozsival/devbox does): its own data root,
  no access to the host's daemon, but it still needs relaxed seccomp/AppArmor and user
  namespaces on the host.
- **Never**: the host socket, a read-write proxy, or a privileged DinD container on the host.
  Each is administrative control of the host and everything it runs.
