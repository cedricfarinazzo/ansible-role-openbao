# CLAUDE.md — ansible-role-openbao

Orientation for Claude Code sessions in this repository. `AGENTS.md` is a symlink to this file.

## Purpose

Public Ansible role `cedricfarinazzo.openbao` (Ansible Galaxy): an OpenBao server or raft cluster from the official packages (apt repository; signed release RPM on EL), in two parts. `main`: install, plugins, seal, TLS, configuration (listener, telemetry, logs, audit devices), environment, service, snapshot timer. `tasks_from: configure`: post-init auth methods, engines, transit keys, policies, token roles, any API object (present or absent), snapshot tokens, with a root token given at run time. Generic by design: no reference to any downstream project, host, user or network in code, defaults, docs or commit messages.

## Layout

- `defaults/main.yml` — every user-facing variable (`openbao_*`), with its generic default.
- `vars/main.yml` — internal paths, the plugin and audit stanzas, the cluster defaults (`retry_join`, cluster address), the assembled configuration (`openbao_config`, JSON), the SAN list, the local API address, the post-init object lists (`openbao_transit_objects`, snapshot policy and role) and the diff (`openbao_object_diff_keys`).
- `tasks/main.yml` — `validate.yml` (every input, cluster membership), `plugins.yml` (installed version per family, no downgrade; download with checksum, unpack per checksum, binary sha256 asserted; before any install), `install.yml` (key fingerprint checked; `install-Debian.yml`: deb822 repository, version held; `install-RedHat.yml`: signed `checksums.txt` checked with `gpgv`, RPM sha256, `dnf versionlock`; groups, polkit rule, was the service running), `tls.yml` (self-signed on the host; a cluster's certificate bundle), `config.yml` (plugin binaries, config validated by `bao operator validate-config`, env file root 0400 with `no_log`, restart and start-order drop-in, `client.env`, scripts, audit log dir and logrotate, snapshot units); then, when a start is due, the PKCS#11 OAEP check (`openbao_pkcs11_oaep_check`), the start, the handlers (restart only a service that was running), the health wait and the running seal type.
- `tasks/configure.yml` — post-init over the HTTP API (`uri`, `no_log` on every task with the token), once per cluster (`openbao_configure_here`); `mounts.yml` (auth methods or engines: type checked, enable, tune, disable) and `api_objects.yml` (any object: read, write only the keys that differ, delete what is absent; `create_only`, `update_only`, `read_path`); then each host's snapshot token. Every read (`GET`) has `check_mode: false`, so check mode compares; check mode tunes existing mounts only.
- `templates/openbao.env.j2` — systemd `EnvironmentFile`, values double-quoted.
- `files/openbao-token-create` — one token from a token role, printed once; `files/openbao-pkcs11-oaep-check` — OAEP round trip on a PKCS#11 key with the PIN from `BAO_HSM_PIN`; `files/openbao-raft-snapshot` — one snapshot with the token in `/etc/openbao/backup.token` (renewed), the newest N kept.
- `handlers/main.yml` — daemon-reload (drop-in change), restart OpenBao (only if it was running before the run: a first start is one start).
- `meta/main.yml` — Galaxy metadata; `platforms` lists exactly what CI tests.
- `molecule/cluster/` — three raft nodes on one docker network, static seal (the same test key everywhere): certificate bundle, `retry_join`, three voters, replication, post-init once, snapshots from a standby. Debian 13 only, one distribution at a time (container names carry no distribution).
- `molecule/seal-migration/` — one node, Debian 13, two SoftHSM keys: init on key A, `openbao_seal_previous` A + `openbao_seal` B, `bao operator unseal -migrate` with two recovery keys, then B alone; verify: unsealed by B with A deleted, the same recovery keys still authorise a root token, A alone stays sealed.
- `molecule/default/` — one node (docker driver, `geerlingguy/docker-<distro>-ansible`), Debian and EL families. `prepare/`: SoftHSM token with an RSA key (CKA_ID 03, label `seal`); failure paths with nothing installed (required env unset, wrong plugin checksum); 2.7.1 installed with `openbao_service_start: false`; a wrong PIN stopped by the OAEP check (`CKR_PIN_INCORRECT`), OpenBao never started. `check` (before converge, and after it with post-init). `converge/`: the role (upgrade to the default version, one start), init once (test only: output kept root-only in `/root/molecule-init.json`), post-init; `idempotence` reruns all three and must change nothing. `verify/`: one start, files, restart policy, non-root client, environment, init 3/2, cluster port on loopback, post-init refuses without a token and a mount of another type, TLS 1.3 only, metrics without a token, JSON logs, file audit and logrotate, tuning and roles read back, create/change/absent of every object kind, a create-only field refused, check mode on missing and differing objects, a root CA by `create_only` + `read_path` made once, snapshots, the periodic token, a restart unsealing through the seal.
- `run-tests.sh` / `Makefile` — local Molecule entry points (`-s cluster` for the cluster scenario); several distros run in parallel, one log each in `.molecule-logs/<scenario>-<distro>.log`.
- `requirements.yml` — collections the role needs at runtime (consumer ranges); `requirements-dev.txt` — controller tooling, exact pins; `molecule/default/collections.yml` — test pins.
- `package.json`, `bun.lock`, `.releaserc.json` — semantic-release tooling only.
- `.github/workflows/` — `ci.yml` (lint, shellcheck, Molecule matrix, cluster job), `pr-title.yml`, `release.yml` (semantic-release after `ci.yml` passes on `main`).

## Conventions

- **Conventional Commits** (`conventionalcommits` preset). `feat:` → minor, `fix:` / `perf:` → patch, `!` or `BREAKING CHANGE:` → major; `docs:` / `ci:` / `chore:` / `test:` / `refactor:` release nothing. A squash merge lands the **PR title** (`pr-title.yml` checks it).
- **Breaking = a consumer must act:** dropping a platform, renaming or removing a variable, changing a default that changes the seal, the listener, the storage path or the certificate.
- **Tags are bare semver** (`1.2.3`). Release notes in GitHub Releases; no `CHANGELOG.md`.
- **No ruleset or branch protection on `main`:** it blocks semantic-release. Changes go through a PR with green CI, by discipline.
- **Variables:** every user-facing variable starts with `openbao_`, is defined in `defaults/main.yml`, asserted in `tasks/validate.yml` (or `configure.yml` for post-init) and documented in `README.md` in the same PR.
- **Post-init items take `state: present|absent`; an item left out is left alone.** Compare only the keys given against what the API reads back; never write an object that reads back the same.
- **Nothing installed before every check passed:** inputs, then plugin checksums, then the repository key fingerprint. Molecule's `prepare` proves the first two.
- **Secrets never logged or stored:** the env file task and every task carrying the root token have `no_log`; the role never runs `bao operator init` (its output stays with the operator).
- **Examples never copy a real deployment:** documentation addresses (192.0.2.0/24, 198.51.100.0/24) and made-up names.
- **GitHub Actions pinned by full commit SHA**, tag in a trailing comment. **Exact pins for tooling**; ranges only in `requirements.yml`.
- **A pinned upstream version in `defaults/`, `vars/` or `molecule/`** (an OpenBao, plugin or tool release the role installs or tests) carries a `# renovate: datasource=<datasource> depName=<name> [extractVersion=<regex>]` line right above it, or Renovate never sees it. Its bump is `fix(deps)` in `defaults/`/`vars/` (a patch release), `chore(deps)` in `molecule/` (no release, not automerged). A checksum pinned next to a version is updated by hand. `renovate.json` is identical in the ssh, power and openbao roles: change all three together.
- **License:** MIT.

## Supported platforms

`meta/main.yml` `platforms`, the CI matrix, the `README.md` table, `run-tests.sh` and the `Makefile` list the same set.

## Commands

- Lint: `source .venv/bin/activate && yamllint . && ansible-lint && shellcheck files/* run-tests.sh`
- Molecule on one distro: `./run-tests.sh debian13`; all, in parallel: `./run-tests.sh all`
- Iterate: `MOLECULE_DISTRO=debian13 molecule converge` then `molecule verify` (venv active, `MOLECULE_ROLE_NAME_CHECK=0`)

## Gotchas

- systemd `EnvironmentFile` expands no `$`: escaping `$` as `$$` reaches the process as `$$`. Only `\` and `"` are escaped inside the double quotes.
- Molecule expands `$VAR` inside `molecule.yml`: a literal `$` in a test value is `$$` there. A Renovate annotation there must not end its regex with `$`.
- SoftHSM 2.6 does RSA-OAEP with SHA-1 only (`CKR_ARGUMENTS_BAD` on decrypt with SHA-256): the scenario sets `rsa_oaep_hash: sha1`; real HSMs keep the `sha256` default.
- The `openbao` user reads the SoftHSM token only through the `softhsm` group (`openbao_user_groups`); otherwise `C_Initialize` fails with `CKR_GENERAL_ERROR`.
- A token role's `token_period` makes the lease periodic, but `token lookup` shows no `period` for it (only for a `-period` given at creation): check `creation_ttl` and a renewal's `lease_duration` instead.
- `bao operator validate-config` checks syntax, not semantics (an unknown storage type passes): the real check is the service starting.
- `deb822_repository` needs `python3-debian` on the host; check mode on a fresh host fails there (`ignore_errors` in check mode).
- Debian's `pcscd` asks polkit (`org.debian.pcsc-lite.access_pcsc`, `access_card`): a system user such as `openbao` is refused without a rule (`openbao_pcsc_access`).

- A PIV token (ykcs11) gives the data object, the certificate and both keys of a slot the same CKA_ID: a seal with `key_id` alone finds the certificate first and fails on its missing `CKA_KEY_TYPE`. Give `key_label` too (the private key's label). SoftHSM has no certificate, so the scenario cannot show it.
- systemd `StartLimitBurst` counts manual starts and restarts too: a burst of 2 refuses the third restart in the interval. Against HSM PIN lockout use `Restart=no`, not a low burst.
- A held package reads `hold ok installed` in `${Status}`: test `${db:Status-Status}` (`installed`).
- `molecule prepare` skips an instance it thinks prepared, even after `destroy`/`create`: `molecule prepare --force` when iterating; `run-tests.sh` (fresh state) is the proof.
- The raft cluster port opens only once raft runs (after init): check it after `bao operator init`.

- pkcs11-tool names SHA-1 `SHA-1` as a hash but `MGF1-SHA1` as an MGF (`Unknown PKCS11 mechanism "SHA1"`); the other hashes have no dash.
- A failure-path test must name the cause it expects (e.g. `CKR_PIN_INCORRECT`): the wrong-PIN test once passed on an unrelated script error.
- `ansible.builtin.uri` does not run in check mode: a registered read has no `.json` (`object of type 'dict' has no attribute 'json'`). A `GET` gets `check_mode: false`.
- `ansible_check_mode` is false under `include_role` `apply: {check_mode: true}`: decide from a registered result (`skipped`), never from that variable.
- Python `re.match` `$` also matches before a trailing newline: validation regexes end with `\Z`.
- `-e name=false` on the command line is the string `"false"`: a boolean extra var is passed as JSON, `-e '{"name": false}'`.
- `rejectattr('state', 'equalto', 'absent')` fails with `object of type 'dict' has no attribute 'state'` when an item has no `state`: normalise the list first (`openbao_engines_norm`), or `reject('in', <the absent items>)`.
- JSON configuration flattens an object with one key into the labels: `{"audit": [{"file": {"file": {"options": ...}}}]}` reads as three labels (`audit type must be specified`). Put `type` and `path` inside the block.
- `join('\n')` inside a folded (`>-`) scalar writes a literal backslash-n (the cluster CA bundle then fails with `failed to parse CA certificate`): build multi-line file content in a `|` block with a `{% for %}` loop.
- Jinja: `{% set x = x | combine(...) %}` inside a `{% for %}` is lost when the loop ends (transit config fields were dropped, no error). Build the dict with a filter (`dict2items | selectattr | items2dict`); mutate a list with `.append` only.
- OpenBao refuses audit devices created through the API (`unsafe_allow_api_audit_creation` is off): they are `audit` stanzas in the configuration, and dropping one disables it.
- No official RPM repository (EPEL ships its own build): EL installs the release RPM, trusting `checksums.txt` verified by `gpgv` against the fingerprint-checked key alone.

## Self Improvement Loop

Keep `CLAUDE.md` and `README.md` accurate, in the same PR as the change. A trap that costs a debugging round gets one Gotchas line: symptom, cause, fix. New fact replaces the old clause; never append a changelog.
