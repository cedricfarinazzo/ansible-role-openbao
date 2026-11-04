# CLAUDE.md — ansible-role-openbao

Orientation for Claude Code sessions in this repository. `AGENTS.md` is a symlink to this file.

## Purpose

Public Ansible role `cedricfarinazzo.openbao` (Ansible Galaxy): an OpenBao server from the official deb, in two parts. `main`: install, plugins, seal, TLS, configuration, environment, service. `tasks_from: configure`: post-init engines, transit keys, policies, token roles, with a root token given at run time. Generic by design: no reference to any downstream project, host, user or network in code, defaults, docs or commit messages.

## Layout

- `defaults/main.yml` — every user-facing variable (`openbao_*`), with its generic default.
- `vars/main.yml` — internal paths, the plugin stanzas, the assembled configuration (`openbao_config`, JSON), the SAN list, the local API address.
- `tasks/main.yml` — `validate.yml` (every input), `plugins.yml` (download with checksum, unpack, binary sha256 asserted; before any install), `install.yml` (key fingerprint checked, deb822 repository, exact version held, extra packages, groups, polkit rule), `tls.yml` (self-signed on the host), `config.yml` (plugin binaries, config validated by `bao operator validate-config`, env file root 0400 with `no_log`, `client.env`, token script), then the service and a wait on `/v1/sys/health`.
- `tasks/configure.yml` — post-init over the HTTP API (`uri`, `no_log` on every task with the token): read, then write only what differs.
- `templates/openbao.env.j2` — systemd `EnvironmentFile`, values double-quoted.
- `files/openbao-token-create` — one token from a token role, printed once.
- `handlers/main.yml` — restart OpenBao.
- `meta/main.yml` — Galaxy metadata; `platforms` lists exactly what CI tests.
- `molecule/default/` — one scenario (docker driver, `geerlingguy/docker-<distro>-ansible`): `prepare/` makes a SoftHSM token with an RSA key (CKA_ID 03) and runs the two failure paths (required env unset, wrong plugin checksum: nothing installed); `converge/`; `verify/` checks files, the environment, init 3/2, post-init twice, the periodic token, a restart unsealing through the seal; the sequence runs `check` on a fresh container before `converge`.
- `run-tests.sh` / `Makefile` — local Molecule entry points; several distros run in parallel, one log each in `.molecule-logs/`.
- `requirements.yml` — collections the role needs at runtime (consumer ranges); `requirements-dev.txt` — controller tooling, exact pins; `molecule/default/collections.yml` — test pins.
- `package.json`, `bun.lock`, `.releaserc.json` — semantic-release tooling only.
- `.github/workflows/` — `ci.yml` (lint, shellcheck, Molecule matrix), `pr-title.yml`, `release.yml` (semantic-release after `ci.yml` passes on `main`).

## Conventions

- **Conventional Commits** (`conventionalcommits` preset). `feat:` → minor, `fix:` / `perf:` → patch, `!` or `BREAKING CHANGE:` → major; `docs:` / `ci:` / `chore:` / `test:` / `refactor:` release nothing. A squash merge lands the **PR title** (`pr-title.yml` checks it).
- **Breaking = a consumer must act:** dropping a platform, renaming or removing a variable, changing a default that changes the seal, the listener, the storage path or the certificate.
- **Tags are bare semver** (`1.2.3`). Release notes in GitHub Releases; no `CHANGELOG.md`.
- **No ruleset or branch protection on `main`:** it blocks semantic-release. Changes go through a PR with green CI, by discipline.
- **Variables:** every user-facing variable starts with `openbao_`, is defined in `defaults/main.yml`, asserted in `tasks/validate.yml` (or `configure.yml` for post-init) and documented in `README.md` in the same PR.
- **Nothing installed before every check passed:** inputs, then plugin checksums, then the repository key fingerprint. Molecule's `prepare` proves the first two.
- **Secrets never logged or stored:** the env file task and every task carrying the root token have `no_log`; the role never runs `bao operator init` (its output stays with the operator).
- **Examples never copy a real deployment:** documentation addresses (192.0.2.0/24, 198.51.100.0/24) and made-up names.
- **GitHub Actions pinned by full commit SHA**, tag in a trailing comment. **Exact pins for tooling**; ranges only in `requirements.yml`.
- **License:** MIT.

## Supported platforms

`meta/main.yml` `platforms`, the CI matrix, the `README.md` table, `run-tests.sh` and the `Makefile` list the same set.

## Commands

- Lint: `source .venv/bin/activate && yamllint . && ansible-lint && shellcheck files/* run-tests.sh`
- Molecule on one distro: `./run-tests.sh debian13`; all, in parallel: `./run-tests.sh all`
- Iterate: `MOLECULE_DISTRO=debian13 molecule converge` then `molecule verify` (venv active, `MOLECULE_ROLE_NAME_CHECK=0`)

## Gotchas

- systemd `EnvironmentFile` expands no `$`: escaping `$` as `$$` reaches the process as `$$`. Only `\` and `"` are escaped inside the double quotes.
- Molecule expands `$VAR` inside `molecule.yml`: a literal `$` in a test value is `$$` there.
- SoftHSM 2.6 does RSA-OAEP with SHA-1 only (`CKR_ARGUMENTS_BAD` on decrypt with SHA-256): the scenario sets `rsa_oaep_hash: sha1`; real HSMs keep the `sha256` default.
- The `openbao` user reads the SoftHSM token only through the `softhsm` group (`openbao_user_groups`); otherwise `C_Initialize` fails with `CKR_GENERAL_ERROR`.
- A token role's `token_period` makes the lease periodic, but `token lookup` shows no `period` for it (only for a `-period` given at creation): check `creation_ttl` and a renewal's `lease_duration` instead.
- `bao operator validate-config` checks syntax, not semantics (an unknown storage type passes): the real check is the service starting.
- `deb822_repository` needs `python3-debian` on the host; check mode on a fresh host fails there (`ignore_errors` in check mode).
- Debian's `pcscd` asks polkit (`org.debian.pcsc-lite.access_pcsc`, `access_card`): a system user such as `openbao` is refused without a rule (`openbao_pcsc_access`).

## Self Improvement Loop

Keep `CLAUDE.md` and `README.md` accurate, in the same PR as the change. A trap that costs a debugging round gets one Gotchas line: symptom, cause, fix. New fact replaces the old clause; never append a changelog.
