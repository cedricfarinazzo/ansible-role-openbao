# 🔑 Ansible Role: OpenBao

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Ansible Galaxy](https://img.shields.io/badge/Ansible%20Galaxy-cedricfarinazzo.openbao-blue)](https://galaxy.ansible.com/cedricfarinazzo/openbao)
[![CI](https://github.com/cedricfarinazzo/ansible-role-openbao/actions/workflows/ci.yml/badge.svg)](https://github.com/cedricfarinazzo/ansible-role-openbao/actions/workflows/ci.yml)

> **An [OpenBao](https://openbao.org) server, or a raft cluster, from the signed official packages: auto-unseal through an HSM, a cloud KMS or a static key, TLS, audit devices, raft snapshots, then the post-init configuration (auth methods, engines, keys, policies, roles) declared and kept in sync.**

Two parts, with the init in between, done by hand so its output (recovery or unseal keys, root token) never passes through Ansible:

1. **Install and seal** (`main`): packages, plugins, seal, storage, TLS, configuration, service, snapshot timer.
2. **Post-init** (`tasks_from: configure`): everything inside OpenBao, with a root token given at run time and never stored.

## 🚀 Quick Start

```yaml
# Install, seal, start
- hosts: bao
  become: true
  roles:
    - role: cedricfarinazzo.openbao
      vars:
        openbao_api_addr: https://192.0.2.10:8200
        openbao_audit_devices:
          - {type: file, path: file, options: {file_path: /var/log/openbao/audit.log}}
        openbao_backup_enabled: true
```

Then, on the host: `. /etc/openbao/client.env && bao operator init`. Then the post-init part:

```yaml
- hosts: bao
  become: true
  vars_prompt:
    - {name: openbao_root_token, prompt: Root token, private: true}
  tasks:
    - ansible.builtin.include_role:
        name: cedricfarinazzo.openbao
        tasks_from: configure
      vars:
        openbao_api_addr: https://192.0.2.10:8200
        openbao_backup_enabled: true
        openbao_secrets_engines:
          - {path: kv, type: kv, options: {version: "2"}}
        openbao_policies:
          - {name: app, rules: 'path "kv/data/app/*" { capabilities = ["read"] }'}
```

The role will:
- ✅ Install the exact `openbao_version`, checked against OpenBao's signing key (fingerprint pinned), and hold it there: a new version upgrades, nothing ever downgrades
- ✅ Download external plugins (e.g. `kms-pkcs11`) and check their sha256 **before anything is installed**
- ✅ Write the seal, storage, listener, telemetry, logging and audit settings as one configuration, validated by `bao operator validate-config`
- ✅ Generate a self-signed TLS certificate on the host (the key never leaves it), naming the API address
- ✅ Keep secrets such as an HSM PIN in a root-only environment file, never logged
- ✅ With an HSM: test the PIN with an RSA-OAEP round trip before each start, so a wrong PIN never reaches the seal's retry counter
- ✅ Join the members of a cluster by `retry_join`, each trusting the others' certificates
- ✅ Save raft snapshots on a timer, keeping the newest
- ✅ Post-init: enable and tune auth methods and engines, create transit keys, policies, token roles and any other API object, or remove them (`state: absent`); write only what differs, so a rerun changes nothing

## 📋 Requirements

| Component | Requirement |
|-----------|-------------|
| **Operating System** | Debian, Ubuntu, Enterprise Linux (see below), systemd |
| **Ansible** | ansible-core 2.15+ (CI tests the version pinned in `requirements-dev.txt`) |
| **Collections** | `community.crypto` (`requirements.yml`) |
| **Privileges** | Root or sudo access on the target hosts |
| **Network** | The hosts reach `openbao.org`, `pkgs.openbao.org` (Debian family) or `github.com` (EL), and the plugin URLs |

### Supported Distributions

Each is tested in CI with Molecule: one node sealed by SoftHSM with the real `kms-pkcs11` plugin. A three-node cluster is tested on Debian 13.

| Distribution | Versions | Package |
|--------------|----------|---------|
| **Debian** | 12, 13 | `pkgs.openbao.org` apt repository, held |
| **Ubuntu** | 24.04, 26.04 | `pkgs.openbao.org` apt repository, held |
| **Rocky Linux** (EL) | 9, 10 | release RPM from GitHub, `dnf versionlock` |

amd64 and arm64: the packages and the openbao-plugins releases ship both.

#### Platform notes

- **Enterprise Linux** has no official OpenBao repository (EPEL ships its own build). The role downloads the release RPM, verifies the signature of the release's `checksums.txt` with `gpgv` against the pinned key alone, then the RPM's sha256. It is tested with SELinux off (containers): an enforcing host may need a file context for `openbao_plugin_directory`.
- **A PIV token (YubiKey, ykcs11)** gives the data object, the certificate and both keys of a slot the same `CKA_ID`: give `key_label` (the private key's label) with `key_id`, or the seal finds the certificate first. Debian's `pcscd` asks polkit: `openbao_pcsc_access: true` lets the `openbao` user in.
- **An HSM PIN with a retry counter** (a YubiKey locks after 3 wrong PINs): every automatic restart is a new login. Set `openbao_service_restart: "no"` and alert on the service; `openbao_pkcs11_oaep_check: true` tests the PIN before each start.
- **Audit devices** live in the configuration: OpenBao refuses to create them through the API (`unsafe_allow_api_audit_creation` is off). Removing one from the list disables it.
- **A cluster** restarts OpenBao on every member of the play at once on a configuration change: use `serial: 1` to roll it. All members need the same seal (the same HSM key, KMS key or static key).

## ⚙️ Configuration

Every input is checked before anything changes: a wrong type or value fails the play. Every default is in [`defaults/main.yml`](defaults/main.yml).

### Install

```yaml
# Exact version: held (apt) or version-locked (dnf); a new value upgrades, the role never downgrades
openbao_version: "2.7.2"
openbao_apt_repo_url: https://pkgs.openbao.org/deb          # Debian family
openbao_release_url: https://github.com/openbao/openbao/releases/download   # EL: RPM and signed checksums.txt
openbao_gpg_key_url: https://openbao.org/assets/openbao-gpg-pub-20240618.asc
# The key must be this one, alone, or nothing is installed
openbao_gpg_key_fingerprint: 66D15FDD87287219C8E15478D200CD702853E6D0
openbao_packages_extra: []         # e.g. [pcscd, ykcs11, opensc] for a YubiKey
openbao_user_groups: []            # extra groups for the openbao user, e.g. [softhsm]
openbao_pcsc_access: false         # polkit rule letting the openbao user talk to pcscd
# openbao-token-create <role>: prints one token from a token role (caller's token from BAO_TOKEN or a silent prompt)
openbao_token_script: false
```

### Plugins

```yaml
# Each: {type (auth, database, kms, secret), name, version (vX.Y.Z), url (a .tar.gz release archive),
#        checksum (its sha256), binary (the file in it), binary_sha256, args?, env?}
# OpenBao rechecks binary_sha256 before each start
openbao_plugins: []
openbao_plugin_directory: /opt/openbao/plugins
```

### Server

```yaml
openbao_api_addr: ""               # required: the address clients use, e.g. https://192.0.2.10:8200
openbao_listener_address: "0.0.0.0:8200"   # TLS always on
# Merged into the TCP listener: tls_min_version, tls_require_and_verify_client_cert, tls_client_ca_file,
# x_forwarded_for_authorized_addrs, telemetry: {unauthenticated_metrics_access: true}, ...
openbao_listener_options: {}
openbao_listeners_extra: []        # more listeners, e.g. [{unix: {address: /run/openbao/bao.sock}}]
openbao_storage:                   # one backend
  raft:
    path: /opt/openbao/data
    node_id: "{{ inventory_hostname }}"
# One seal stanza: {pkcs11: {...}}, {awskms: {...}}, {static: {...}}; {} = Shamir keys
openbao_seal: {}
openbao_ui: false
openbao_log_level: info            # trace, debug, info, warn, error
openbao_log_format: standard       # standard or json
openbao_telemetry: {}              # e.g. {prometheus_retention_time: 24h, disable_hostname: true}
openbao_config_extra: {}           # merged last: any other top-level setting
```

The configuration is written as JSON (valid OpenBao configuration) to `/etc/openbao/openbao.hcl`.

### Audit devices

```yaml
# Each: {type (file, syslog, socket, http), path, description?, local?, options} (option values are strings)
openbao_audit_devices: []          # e.g. [{type: file, path: file, options: {file_path: /var/log/openbao/audit.log}}]
openbao_audit_log_dir: /var/log/openbao   # a file device writes directly in it (owned by openbao)
openbao_audit_logrotate: true      # daily, then a reload: SIGHUP reopens the files
openbao_audit_logrotate_keep: 14
```

### Secrets in the environment

```yaml
# NAME: value, in /etc/openbao/openbao.env (root, 0400); never logged
openbao_environment: {}            # e.g. {BAO_HSM_PIN: "{{ lookup('env', 'BAO_HSM_PIN') }}"}
# Names that must be set and non-empty, or the role stops before any change
openbao_environment_required: []
```

### Service

```yaml
# false: install and configure only, neither started nor enabled (test an HSM PIN by hand first)
openbao_service_start: true
# systemd Restart=; with an HSM PIN retry counter use "no" and alert on the service
openbao_service_restart: on-failure
# They count manual starts too: a low burst refuses ordinary restarts
openbao_service_start_limit_interval_sec: 60
openbao_service_start_limit_burst: 3
# Before each start: an RSA-OAEP round trip on the seal's PKCS#11 key, as the openbao user, one PIN login.
# Needs opensc and openbao_seal.pkcs11 with lib, key_id, slot or token_label. Skipped on a rerun with no change.
openbao_pkcs11_oaep_check: false
```

### TLS

```yaml
openbao_tls_self_signed: true      # an ECDSA P-384 key and a self-signed certificate, generated on the host
openbao_tls_common_name: "{{ ansible_facts['fqdn'] }}"
# IP:... / DNS:...; 127.0.0.1, localhost and the host of openbao_api_addr are always added
openbao_tls_subject_alt_names: []
openbao_tls_valid_days: 3650
openbao_tls_dir: /opt/openbao/tls  # the key 0600, the certificate 0644
openbao_tls_cert_file: "{{ openbao_tls_dir }}/tls.crt"   # bring your own with openbao_tls_self_signed: false
openbao_tls_key_file: "{{ openbao_tls_dir }}/tls.key"
# The CA clients and the role trust: the certificate itself; in a cluster, the bundle of every member's; else your CA
openbao_tls_ca_file: "{{ openbao_tls_cert_file }}"
```

`/etc/openbao/client.env` sets `BAO_ADDR` and `BAO_CACERT` for local use: `. /etc/openbao/client.env && bao status`.

### Cluster

```yaml
# Inventory group of the raft nodes; "" = a single node. Every member must be in the play.
openbao_cluster_group: ""
# Default: one entry per other member, leader_api_addr its openbao_api_addr, trusting openbao_tls_ca_file.
# Give your own list (e.g. auto_join) to replace it.
openbao_raft_retry_join: [...]
# Single node: https://127.0.0.1:8201 and 127.0.0.1:8201; cluster: the host of openbao_api_addr, port 8201,
# listening on every address
openbao_cluster_addr: ...
openbao_cluster_listen_address: ...
```

Each member keeps its own self-signed certificate. Every member's certificate is collected into `/opt/openbao/tls/ca-bundle.pem` on each node, which `retry_join` and the clients trust. With your own certificates, set `openbao_tls_ca_file` to your CA.

### Raft snapshots

```yaml
openbao_backup_enabled: false      # openbao-snapshot.timer, running openbao-raft-snapshot
openbao_backup_dir: /var/backups/openbao   # root, 0700
openbao_backup_schedule: daily     # systemd OnCalendar
openbao_backup_keep: 7             # the newest kept
openbao_backup_token_period: 604800   # seconds; each run renews the token
```

The post-init part creates the `openbao-snapshot` policy (read on `sys/storage/raft/snapshot`) and token role, then one periodic orphan token per host with snapshots enabled, in `/etc/openbao/backup.token` (root, 0400). It keeps a token while it is valid and replaces an expired one. A snapshot is encrypted by the seal: restoring it needs the same seal or the unseal keys. In a cluster, enable it on one member (a standby forwards the request).

### Post-init (`tasks_from: configure`)

```yaml
openbao_root_token: ""             # given at run time only (-e or vars_prompt); the part stops without it
openbao_addr: ...                  # the API on the host: the listener, loopback for a wildcard

# Every item takes state: present (default) or absent; an item left out of a list is left alone.
# Durations in seconds (3600, not 1h) and lists as lists: as the API reads them back.

# {path, type, description?, config?}; config is the mount tuning (default_lease_ttl, max_lease_ttl, ...)
openbao_auth_methods: []
# {path, type, description?, config?, options?}; options values are strings ({version: "2"} for kv v2)
openbao_secrets_engines: []
# {mount, name, type? (aes256-gcm96), derived?, convergent_encryption?, key_size?, exportable?,
#  allow_plaintext_backup?, auto_rotate_period?, deletion_allowed?, min_decryption_version?, min_encryption_version?}
# type, derived, convergent_encryption and key_size cannot change once created
openbao_transit_keys: []
openbao_policies: []               # {name, rules} (HCL)
# {name, allowed_policies, ...any token role parameter: orphan, renewable, token_period, token_explicit_max_ttl,
#  token_bound_cidrs, token_type, token_no_default_policy, token_num_uses, path_suffix}
openbao_token_roles: []
# {path, data}: any other object written with a POST and read back with a GET
openbao_api_resources: []
```

Each item is read first and written only when a key it gives differs from what the API reads back. A key the API never reads back (a password) is written when the object is created only. `absent` disables a mount (its data is destroyed), deletes a key (after allowing it), a policy, a role or an object. A path already enabled with another type stops the run. In a cluster the writes run once, on the first member in the play. Every task that carries the root token has `no_log`.

## 🎯 Usage Examples

### A transit unseal service sealed by an HSM

Values are illustrative: take the plugin sums from the openbao-plugins release you pin, and the library, token and key names from your HSM.

```yaml
- hosts: unseal
  become: true
  roles:
    - role: cedricfarinazzo.openbao
      vars:
        openbao_api_addr: https://198.51.100.20:8200
        openbao_tls_common_name: unseal.example.org
        openbao_tls_subject_alt_names: ["DNS:unseal.example.org"]
        openbao_packages_extra: [pcscd, opensc]
        openbao_pcsc_access: true
        openbao_token_script: true
        openbao_plugins:
          - type: kms
            name: pkcs11
            version: vX.Y.Z
            url: https://github.com/openbao/openbao-plugins/releases/download/kms-pkcs11-vX.Y.Z/openbao-plugin-kms-pkcs11_linux_amd64_v1.tar.gz
            checksum: "<sha256 of the archive>"
            binary: openbao-plugin-kms-pkcs11_linux_amd64_v1
            binary_sha256: "<sha256 of the binary>"
        openbao_seal:
          pkcs11:
            lib: /usr/lib/x86_64-linux-gnu/<vendor>-pkcs11.so
            token_label: unseal-token
            key_id: "01"
            key_label: unseal-key   # a PIV token: several objects share one CKA_ID
            rsa_oaep_hash: sha256
        openbao_environment:
          BAO_HSM_PIN: "{{ lookup('env', 'BAO_HSM_PIN') }}"
        openbao_environment_required: [BAO_HSM_PIN]
        openbao_service_restart: "no"   # a PIN with a retry counter
        openbao_pkcs11_oaep_check: true
```

Then `bao operator init -recovery-shares=5 -recovery-threshold=3`, then the post-init part with:

```yaml
        openbao_secrets_engines: [{path: transit, type: transit}]
        openbao_transit_keys: [{mount: transit, name: unseal}]
        openbao_policies:
          - name: unseal
            rules: |
              path "transit/encrypt/unseal" { capabilities = ["update"] }
              path "transit/decrypt/unseal" { capabilities = ["update"] }
        # Periodic: never expires while renewed; orphan: outlives the revocation of the root token
        openbao_token_roles:
          - {name: unseal, allowed_policies: [unseal], token_period: 86400, orphan: true}
```

`openbao-token-create unseal` on the host prints the token for the other OpenBao's transit seal.

### A three-node raft cluster

```yaml
# inventory: group "bao" with bao-1, bao-2, bao-3
- hosts: bao
  become: true
  roles:
    - role: cedricfarinazzo.openbao
      vars:
        openbao_cluster_group: bao
        openbao_api_addr: "https://{{ inventory_hostname }}.example.org:8200"
        openbao_seal: {awskms: {region: eu-west-3, kms_key_id: "<key id>"}}
```

`bao operator init` on one node: the others join through `retry_join` and unseal through the seal. Run the post-init part on `hosts: bao`: it writes once.

### Prometheus metrics, JSON logs, TLS 1.3 only

```yaml
openbao_listener_options:
  tls_min_version: tls13
  telemetry: {unauthenticated_metrics_access: true}
openbao_telemetry: {prometheus_retention_time: 24h, disable_hostname: true}
openbao_log_format: json
```

Scrape `https://<host>:8200/v1/sys/metrics?format=prometheus`.

### AppRole for an application

```yaml
openbao_auth_methods:
  - {path: approle, type: approle, config: {default_lease_ttl: 3600, max_lease_ttl: 86400}}
openbao_api_resources:
  - path: auth/approle/role/app
    data: {token_policies: [app], token_ttl: 1800, secret_id_ttl: 0}
```

### Remove what is no longer wanted

```yaml
openbao_secrets_engines:
  - {path: old-kv, type: kv, state: absent}     # disabled: its data is destroyed
openbao_transit_keys:
  - {mount: transit, name: retired, state: absent}
openbao_policies:
  - {name: legacy, state: absent}
```

## 🚫 Out of scope, on purpose

- **Init and unseal keys:** the role never runs `bao operator init` or submits unseal keys, so the keys and the root token never reach the controller.
- **Firewall:** open 8200 (and 8201 between cluster members) with the host's firewall role.
- **A binary or zip install:** the signed packages are the trust anchor.

## 🧪 Testing

Two Molecule scenarios, in Docker. The tooling is pinned in `requirements-dev.txt`; `run-tests.sh` installs it into `.venv`.

- **default**, on every supported distribution. SoftHSM stands in for the HSM, with the real `kms-pkcs11` plugin.
  - **prepare:** the role stops with nothing installed on an unset required variable or a wrong plugin checksum; `openbao_service_start: false` installs an older release without starting it; a wrong PIN is stopped by the OAEP check before any start.
  - **check:** check mode.
  - **converge:** upgrades the held package with one start, inits (3 recovery shares, threshold 2), runs post-init.
  - **verify:** TLS 1.3 only, metrics without a token, JSON logs, the file audit log and its rotation, tuning and roles read back, every kind of object created, changed and removed, a create-only field refused, two snapshots kept of three, a periodic token doing transit and nothing else, a restart unsealing through the seal.
  - **idempotence:** install, init and post-init rerun: nothing changes.
- **cluster**, on Debian 13: three nodes with a static seal join by `retry_join` through the certificate bundle; three voters, a write on one node read on another, post-init written once, snapshots from a standby with its own token, then idempotence.

```bash
# One distribution
./run-tests.sh debian13

# Every supported distribution, in parallel (logs in .molecule-logs/)
make molecule-test-all

# The three-node cluster
./run-tests.sh -s cluster debian13

# Lint
source .venv/bin/activate && yamllint . && ansible-lint && shellcheck files/* run-tests.sh
```

## 🚢 Releases

Once CI passes on `main`, [semantic-release](https://github.com/semantic-release/semantic-release) cuts the version from [Conventional Commits](https://www.conventionalcommits.org/): `fix:` releases a patch, `feat:` a minor, a `!` or `BREAKING CHANGE:` footer a major. A squash merge lands the pull request title (checked in CI), a merge commit lands each branch commit, so both must follow the convention. Each release gets a bare semver tag (`1.2.3`) and GitHub release notes; Ansible Galaxy imports the new tag from the repository. [Renovate](https://docs.renovatebot.com/) keeps the tooling and the pinned GitHub Actions up to date.

## 📦 Dependencies

- ✅ **Ansible Core Modules** (built-in)
- ✅ **OS packages** `openbao`, `gnupg`, `ca-certificates`, `python3-cryptography`, `python3-debian` (Debian family), `python3-dnf-plugin-versionlock` (EL), `logrotate` (file audit), `polkitd` (`openbao_pcsc_access`)
- ✅ **Collection** `community.crypto` (the TLS key and certificate), from `requirements.yml`

## 👥 Authors & Contributors

**Cédric Farinazzo** ([@cedricfarinazzo](https://github.com/cedricfarinazzo)) - *Author and Maintainer*

## 📄 License

MIT
