# AKTIN Update Agent — Architecture & Developer Overview

This document describes how the update agent actually works today, based on a read-through of
every script and unit file in `src/`. It exists because the `README.md` was written for the
original Debian-only design and has drifted from the code as Docker support was added — where
the two disagree, this document reflects the **current code**, and the discrepancies are called
out explicitly in [Known Divergences](#known-divergences--rough-edges) so they can be triaged.

## 1. What this package is

A Debian package (`aktin-notaufnahme-updateagent`) that lets a *caller* (typically the AKTIN
web UI, or an operator) remotely trigger two things for an AKTIN DWH installation:

1. **Info**: "what version is installed vs. what version is available?"
2. **Update**: "install the available version now."

It supports **two independent deployment styles of the DWH**, detected/handled separately:

| Mode | DWH runs as | Update mechanism | Caller reaches it via |
|---|---|---|---|
| **Debian-native** | `wildfly.service` installed directly on the host via apt | `apt-get install <dwh-package>` + restart WildFly | `127.0.0.1` only |
| **Docker** | A `docker compose` stack (WildFly, httpd, DB containers) | `docker compose down/pull/up` against a fresh `compose.yml` pulled from GitHub | any reachable interface (`0.0.0.0`), tenant selected by source IP |

Both modes can be present **on the same host at the same time** (e.g. a host running several
Docker-based DWH tenants, or a mixed native+Docker setup) — the install scripts detect what's
present and provision accordingly rather than assuming one or the other.

## 2. Core mechanism: systemd socket activation

Nothing runs as a long-lived daemon. Each of the four operations is a `.socket` unit with
`Accept=yes`, paired with a templated `@.service` unit:

- systemd listens on the port itself; no process is running until a client connects.
- On each connection, systemd spawns **one instance** of the `@.service`, with the accepted
  connection's socket wired to the process's stdin/stdout, and `%i` set to the connection index.
- Because `Accept=yes`, systemd also exports `REMOTE_ADDR` / `REMOTE_PORT` env vars for the
  connecting peer — this is how the Docker scripts know *who* is calling without any application
  protocol (see §4).
- `StartLimitBurst=3` / `StartLimitIntervalSec=300` on the `@.service` units throttles runaway
  restarts if a script keeps failing.

This is effectively inetd-style activation via systemd: "connecting to the port" *is* the API.
There is no request parsing, no auth, no response body beyond whatever the script happens to
have written to its stdout (which is discarded/logged, not read as a protocol reply) — the real
output is the `info`/`result` files the script writes to disk, which the caller is expected to
read separately (e.g. AKTIN's UI mounts/reads the update directory).

## 3. Ports

| Port | Bind address | Unit | Purpose |
|---|---|---|---|
| 1002 | `127.0.0.1` | `*-info@.service` | Debian-native: refresh version info |
| 1003 | `127.0.0.1` | `*@.service` | Debian-native: run the update |
| 1004 | `0.0.0.0` | `*-docker-info@.service` | Docker: refresh version info for a tenant |
| 1005 | `0.0.0.0` | `*-docker@.service` | Docker: run the update for a tenant |

**This asymmetry is deliberate and important**: the Debian-native services are localhost-only
(single host, single instance, trusted local caller). The Docker services are bound to all
interfaces because the caller is expected to be a *container* connecting in from a
docker-compose network, not a local process — see §4. None of the four sockets have any
authentication; the trust boundary is entirely "who can open a TCP connection to this port."

## 4. Debian-native workflow

```
apt update  ──(APT::Update::Post-Invoke hook)──▶  /usr/bin/<pkg>-info
                                                       writes /var/lib/aktin/update/info

client → 127.0.0.1:1002 ──▶ *-info@.service ──▶ ExecStart = `apt update`
                                                   (which itself re-triggers the hook above)

client → 127.0.0.1:1003 ──▶ *@.service ──▶ /usr/bin/<pkg>
                                              apt-get install <dwh-package>
                                              systemctl restart wildfly.service; sleep 30
                                              writes /var/lib/aktin/update/result
```

Two non-obvious points worth internalizing:

- **The info socket does not run the info script directly.** `service-info@.service`'s
  `ExecStart` is literally `apt update`. Version info is produced as a *side effect* through the
  separate APT hook `/etc/apt/apt.conf.d/99<pkg>-info`
  (`APT::Update::Post-Invoke {"/usr/bin/<pkg>-info";}`), which fires on **any** `apt update` —
  including ones run by `unattended-upgrades`/cron, not just ones triggered through port 1002.
  So `info` can be refreshed without anyone ever touching the socket.
- The update script (`/usr/bin/<pkg>`) treats an `apt-get install` run as failed if grep finds a
  `W:`/`E:` line in its captured output, otherwise restarts WildFly and waits a flat 30s before
  declaring success (comment in the script itself calls this a "dirty workaround").

Result files:
- `/var/lib/aktin/update/info` — `version.installed`, `version.candidate`, `version.time`
- `/var/lib/aktin/update/result` — `update.success`, `update.time`

## 5. Docker workflow

This is the newer, more involved path (`src/resources/service-docker/`, backed by
`helpers.sh`). The central design idea:

> **The calling client's source IP is used to identify *which* docker-compose DWH stack (tenant)
> the request is for.** There is no other identifier in the protocol.

Concretely, `get_compose_prefix_from_ip()` walks all running containers, inspects each one's
bridge-network IP address, and returns the `com.docker.compose.project` label of whichever
container's IP matches the caller's `REMOTE_ADDR`. This only works because Docker's default
bridge networking means a container's own IP is what the host observes as the source address
when that container opens a connection to a host-bound port. In other words: **the caller is
expected to be a container belonging to the same compose stack it wants updated** (e.g. that
stack's httpd/UI container calling back out to the host's update agent) — not an arbitrary
external client.

From the resolved `dwh_prefix` (the compose project name), everything else is derived by
convention:
- WildFly container name: `<prefix>-wildfly-1` (default `docker compose` container naming)
- Per-tenant update directory: `/var/lib/docker/volumes/<prefix>_aktin_data/_data/update`
  (i.e. inside the named volume `<prefix>_aktin_data` that compose creates for that project)
- Compose project directory: read from the WildFly container's
  `com.docker.compose.project.working_dir` / `...config_files` labels

### 5a. Docker info (`port 1004` → `*-docker-info`)

1. Resolve `dwh_prefix` / `wildfly_container` / `update_dir` from caller IP.
2. `installed` = parse `jboss-cli.sh --connect --command="deployment-info"` inside the WildFly
   container for the deployed `dwh-j2ee-*.ear` name.
3. `latest` = highest semver tag from the GitHub API
   (`api.github.com/repos/aktin/dwh-j2ee/tags`).
4. Write `info` (installed/candidate/time + `request.client_ip/port/prefix`) into the tenant's
   update dir.

### 5b. Docker update (`port 1005` → `*-docker`)

1. Resolve prefix/container/update dir/compose dir as above.
2. Back up the current `server.log` out of the WildFly container into the update dir.
3. `cd` into the compose project dir; `docker compose down`.
4. Download the **latest** `compose.yml` release asset from
   `github.com/aktin/docker-aktin-dwh/releases/latest` — i.e. the update doesn't just bump the
   image tag, it replaces the compose file wholesale with whatever the latest published release
   ships.
5. `docker compose pull && docker compose up -d`.
6. `docker_wait_for_deployment`: poll `deployment-info` for up to 300s (5s interval) until the
   `.ear` shows up.
7. `docker_post_update_validation`: compares the now-installed version against the `candidate`
   previously written to `info` (note: this means an update run depends on a prior/co-located
   info run having populated `info` with the right candidate — it does not re-derive "latest"
   itself).
8. Write `result` (`update.success`, `update.time`, `update.message=not_implemented` — static
   placeholder, always this literal string today — plus request metadata) into the update dir.
9. Copy the backed-up `server.log` into the new container as `server.log.1`.

## 6. Install / uninstall lifecycle

Package management scripts live in `src/debian/`; they're templated into `DEBIAN/{preinst,
postinst,prerm,control}` by `build.sh`.

```
preinst install
 ├─ is_installed_debian()  → wildfly.service unit file present?
 ├─ is_installed_docker()  → all 3 required aktin/* images present locally?
 └─ writes /tmp/summary_aktin-updateagent_preinstall.txt
       debian_installed=<0|1>   (shell exit-code convention: 0 = present)
       docker_installed=<0|1>

[dpkg unpacks files]

postinst configure
 ├─ sources the /tmp summary file written by preinst
 ├─ if debian_installed: mkdir /var/lib/aktin/update
 ├─ if docker_installed: mkdir <volume>/_data/update for every *_aktin_data volume found
 │     under /var/lib/docker/volumes/  (i.e. every compose-managed tenant, not just one)
 ├─ systemctl daemon-reload
 └─ runs /usr/lib/<pkg>/socket-setup configure
       ├─ mkdir -p the update dir (again)
       └─ systemctl enable + start all 4 socket units
```

```
prerm remove
 ├─ /usr/lib/<pkg>/socket-setup remove → systemctl stop+disable the 4 socket units
 ├─ rm -r /var/lib/aktin/update
 └─ rm -r every */_data/update under /var/lib/docker/volumes/*_aktin_data/
```

Note the package **installs cleanly with neither mode detected** — `preinst` never aborts
installation, it only records what it found, and `postinst` simply skips the directories that
don't apply. This is why the base package doesn't require an AKTIN DWH instance at all; the
`socket-setup` script is the explicit "instance-specific" step, callable independently
(`sudo /usr/lib/<pkg>/socket-setup configure`) — useful for re-running host-coupled setup without
a full package reinstall.

## 7. Build process (`src/debian/build.sh`)

Pure templating, no compilation:

1. Reads `PACKAGE_VERSION` from `src/resources/versions`.
2. For every file under `src/resources/{service-debian,service-docker}/` and `src/debian/`,
   runs `sed` to substitute `__PACKAGE_NAME__`, `__DWH_PACKAGE_NAME__` (derived from
   `PACKAGE_NAME` by keeping its first two `-`-separated tokens + `-dwh`, e.g.
   `aktin-notaufnahme-updateagent` → `aktin-notaufnahme-dwh`), `__AKTIN_UPDATE_DIR__`
   (`/var/lib/aktin/update`, hardcoded in `build.sh`), and `__PACKAGE_VERSION__`.
3. Assembles the result under `src/build/<pkg>_<version>/` following FHS-ish package layout
   (`usr/bin`, `usr/lib/<pkg>`, `lib/systemd/system`, `etc/apt/apt.conf.d`, `DEBIAN`).
4. `dpkg-deb --build` produces the `.deb`.

Flags: `--cleanup` (rm build dir after packaging), `--skip-deb-build` (template only, no
`dpkg-deb`), `--full-clean` (also wipes `src/build/` and `src/downloads/` first). Note this is
one more flag than the README documents (`--full-clean` is undocumented there), and the README's
invocation path (`./build.sh ...` from repo root) doesn't match the script's actual location
(`src/debian/build.sh`).

CI (`.github/workflows/ci-rc.yml`) builds/deploys on any `v<major>.<minor>*` tag push via shared
`aktin/aktin-github-scripts` reusable workflows, targeting the `jammy-testing` apt repo codename.

## 8. File/directory reference

| Path | What |
|---|---|
| `/usr/bin/<pkg>` | Debian update script |
| `/usr/bin/<pkg>-info` | Debian info script |
| `/usr/bin/<pkg>-docker` | Docker update script |
| `/usr/bin/<pkg>-docker-info` | Docker info script |
| `/usr/lib/<pkg>/socket-setup` | Instance provisioning helper (configure/remove) |
| `/usr/lib/<pkg>/helpers.sh` | Shared functions sourced by the two Docker scripts |
| `/lib/systemd/system/<pkg>{,-info,-docker,-docker-info}{,@}.socket|.service` | The 8 unit files |
| `/etc/apt/apt.conf.d/99<pkg>-info` | APT post-invoke hook → runs `<pkg>-info` after every `apt update` |
| `/var/lib/aktin/update/{info,result,log}` | Debian-native status files |
| `/var/lib/docker/volumes/<prefix>_aktin_data/_data/update/{info,result,log,server.log*}` | Per-tenant Docker status files |

## 9. Known divergences / rough edges

Found while reading the code; flagged here rather than silently "fixed" since some may be
intentional/in-progress:

- **README says Docker `info`/`result` are placeholders.** They aren't — both are fully
  implemented (§5). The README predates this work and needs updating.
- **README lists the AKTIN DWH package as a hard prerequisite** and doesn't mention Docker mode
  at all beyond the port list. In reality, per §6, neither mode is required at install time.
- **`socket-setup configure` has `require_wildfly_user`, `require_systemd`, and
  `set_wildfly_permissions` all commented out.** The README's claim that the instance helper
  "applies host-coupled configuration such as wildfly ownership" is currently **not happening in
  practice** — the update directory is created but never `chown`'d to `wildfly`.
- **`service-docker` line 36**:
  `$(journalctl -u 'aktin-notaufnahme-updateagent-docker*' -f) > $update_dir/log` — running
  `journalctl -f` (follow mode) inside a `$(...)` command substitution will block waiting for new
  log lines that never stop arriving; this looks like leftover debugging and, as written, would
  hang the update script rather than capture a log snapshot.
- **`update.message=not_implemented`** is a hardcoded literal in the Docker `result` file, not
  an actual status message.
- **Both `.socket` unit files set `StandardOutput=socket` under `[Socket]`.** That directive
  belongs to `[Service]` sections; under `[Socket]` it's likely inert (systemd would warn about
  an unrecognized key), so double-check whether it's doing anything before relying on it.
- Several explicit `# todo` markers left in the code worth tracking as backlog:
  `helpers.sh` (`docker_post_update_validation`: "find a better check for testing if update was
  successful"), `prerm` (hardcoded volumes basedir "inject this value in build.sh"),
  `socket-setup` (`remove`: "function to delete sockets").
- Build invocation in the README (`./build.sh ...`) doesn't match the script's actual path
  (`src/debian/build.sh`), and omits the `--full-clean` flag.

## 10. Suggested mental model for new contributors

Think of this repo as **two parallel, independently-triggerable update pipelines that share a
packaging/lifecycle shell**:

- The *Debian pipeline* is simple and old: `apt` does the work, the agent just remote-triggers it
  and shells out to check WildFly afterward. Single instance per host, localhost-only.
- The *Docker pipeline* is newer, more complex, and multi-tenant: it has to first figure out
  *which* compose stack a request is even about (by matching the caller's IP against container
  network addresses), then drive that stack's `docker compose` lifecycle directly and reconcile
  against a GitHub-hosted compose file/release, rather than delegating to a package manager.

Everything else (socket activation, the `preinst`/`postinst`/`prerm` scaffolding, `socket-setup`)
exists to install, provision, and tear down both pipelines side by side on the same host.
