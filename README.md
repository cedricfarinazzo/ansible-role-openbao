# Ansible role: OpenBao

[![CI](https://github.com/cedricfarinazzo/ansible-role-openbao/actions/workflows/ci.yml/badge.svg)](https://github.com/cedricfarinazzo/ansible-role-openbao/actions/workflows/ci.yml)

An [OpenBao](https://openbao.org) server, or a raft cluster, from the official packages, set up in two parts:

1. **Install and seal** (`main`): an exact version (the apt repository on Debian and Ubuntu, the signed release RPM on Enterprise Linux, the signing key's fingerprint pinned), external plugins whose checksums are checked **before anything is installed**, a seal stanza (auto-unseal through a KMS plugin such as PKCS#11, a static key, or Shamir keys), raft storage on one node or several (`retry_join`), a self-signed TLS certificate generated on each host, listener options, telemetry, logging, audit devices with log rotation, raft snapshots on a timer, and a root-only environment file for secrets such as an HSM PIN.
2. **Post-init** (`tasks_from: configure`): auth methods, secrets engines (with their tuning and options), transit keys, ACL policies, token roles and any other API object, each present or absent, with a root token given at run time and never stored.

`bao operator init` runs between the two, by hand: its output (recovery or unseal keys, root token) never passes through Ansible.

## Supported platforms

| Distribution | Versions | Package |
| ------------ | -------- | ------- |
| Debian | 12 (bookworm), 13 (trixie) | `pkgs.openbao.org` apt repository, held |
| Ubuntu | 24.04 (noble), 26.04 (resolute) | `pkgs.openbao.org` apt repository, held |
| Rocky Linux (Enterprise Linux) | 9, 10 | release RPM from GitHub, `dnf versionlock` |

amd64 and arm64 (the packages and the openbao-plugins releases ship both). On Enterprise Linux the role is tested with SELinux off (containers): an enforcing host may need a file context for `openbao_plugin_directory`.

## Requirements

- Ansible 2.15+ and the `community.crypto` collection (`requirements.yml`).
- The host reaches `openbao.org`, `pkgs.openbao.org` (Debian family) or `github.com` (Enterprise Linux), and the plugin URLs.

## Role variables

Every default is in [`defaults/main.yml`](defaults/main.yml).

### Install

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `openbao_version` | `2.7.2` | Exact version, held (apt) or version-locked (dnf); a new value upgrades it; the role never downgrades |
| `openbao_apt_repo_url` | `https://pkgs.openbao.org/deb` | apt repository (Debian family) |
| `openbao_release_url` | GitHub releases of `openbao/openbao` | Release RPM and `checksums.txt` (Enterprise Linux): the checksums' signature is checked against the key, then the RPM's sha256 |
| `openbao_gpg_key_url` | OpenBao's 2024 key | Signing key |
| `openbao_gpg_key_fingerprint` | `66D15FDD…53E6D0` | The key must be this one, alone, or nothing is installed |
| `openbao_packages_extra` | `[]` | More packages, e.g. `[pcscd, ykcs11, opensc]` for a YubiKey |
| `openbao_user_groups` | `[]` | Extra groups for the `openbao` user (e.g. `softhsm`) |
| `openbao_pcsc_access` | `false` | polkit rule letting the `openbao` user talk to `pcscd` (installs polkit) |
| `openbao_token_script` | `false` | Install `openbao-token-create <role>`: prints one token from a token role, the caller's token from `BAO_TOKEN` or a silent prompt |

### Plugins

`openbao_plugins`: a list, each with `type` (`auth`, `database`, `kms`, `secret`), `name`, `version` (`vX.Y.Z`), `url` (a `.tar.gz` release archive), `checksum` (its sha256), `binary` (the file in the archive), `binary_sha256` (the binary's sha256, rechecked by OpenBao before each start) and optional `args` and `env`. They land in `openbao_plugin_directory` (`/opt/openbao/plugins`) and in the configuration as `plugin "<type>" "<name>"` stanzas.

### Server

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `openbao_api_addr` | (required) | Address clients use, e.g. `https://192.0.2.10:8200`; its host is added to the certificate |
| `openbao_listener_address` | `0.0.0.0:8200` | TCP listener (TLS always on) |
| `openbao_listener_options` | `{}` | Merged into the TCP listener: `tls_min_version`, `tls_require_and_verify_client_cert`, `tls_client_ca_file`, `x_forwarded_for_authorized_addrs`, `telemetry`, ... |
| `openbao_listeners_extra` | `[]` | More listener stanzas, e.g. `[{unix: {address: /run/openbao/bao.sock}}]` |
| `openbao_storage` | raft in `/opt/openbao/data` | One storage backend |
| `openbao_seal` | `{}` | One seal stanza, e.g. `{pkcs11: {...}}`; `{}` keeps Shamir keys |
| `openbao_ui` | `false` | Web UI |
| `openbao_log_level`, `openbao_log_format` | `info`, `standard` | `trace` … `error`; `standard` or `json` |
| `openbao_telemetry` | `{}` | `telemetry` stanza, e.g. `{prometheus_retention_time: 24h, disable_hostname: true}` |
| `openbao_audit_devices` | `[]` | `{type (file, syslog, socket, http), path, description?, local?, options}`; option values are strings |
| `openbao_audit_log_dir` | `/var/log/openbao` | A `file` device writes directly in it (owned by `openbao`) |
| `openbao_audit_logrotate`, `openbao_audit_logrotate_keep` | `true`, `14` | Daily logrotate of `*.log` there, then a reload (SIGHUP reopens the files) |
| `openbao_config_extra` | `{}` | Merged last into the configuration (any other top-level setting) |
| `openbao_environment` | `{}` | `NAME: value` for the server, in `/etc/openbao/openbao.env` (root, 0400); never logged |
| `openbao_environment_required` | `[]` | Names that must be set and non-empty, or the role stops before any change |

The configuration is written as JSON (valid OpenBao configuration) to `/etc/openbao/openbao.hcl` and checked with `bao operator validate-config`. Audit devices live in the configuration: OpenBao refuses to create them through the API (`unsafe_allow_api_audit_creation`), and removing one from the list disables it.

### Cluster

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `openbao_cluster_group` | `""` | Inventory group of the raft nodes; `""` is a single node. Every member must be in the play |
| `openbao_raft_retry_join` | one entry per other member | `leader_api_addr` is that member's `openbao_api_addr`, trusting `openbao_tls_ca_file`; give your own list (e.g. `auto_join`) to replace it |
| `openbao_cluster_addr` | single: `https://127.0.0.1:8201`; cluster: the host of `openbao_api_addr`, port 8201 | Raft cluster address |
| `openbao_cluster_listen_address` | single: `127.0.0.1:8201`; cluster: `0.0.0.0:8201` | Where the cluster port listens |

Each member keeps its own self-signed certificate; every member's certificate is collected into `/opt/openbao/tls/ca-bundle.pem` on each node (the default `openbao_tls_ca_file` in a cluster), which `retry_join` and the clients trust. With your own certificates, set `openbao_tls_ca_file` to your CA. All members need the same seal (the same HSM key, KMS key or static key). Init one node; the others join and, with an auto-unseal seal, unseal themselves. A configuration change restarts OpenBao on every member of the play at once: use `serial: 1` to roll it.

### Service

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `openbao_service_start` | `true` | `false`: install and configure only, neither started nor enabled (test an HSM PIN by hand first) |
| `openbao_service_restart` | `on-failure` | systemd `Restart=`. Every automatic restart retries the seal and its HSM login: with a PIN retry counter (a YubiKey locks after 3 wrong PINs) use `"no"` and alert on the service |
| `openbao_pkcs11_oaep_check` | `false` | Before each start or restart: an RSA-OAEP round trip on the seal's PKCS#11 key (`openbao-pkcs11-oaep-check`), as the `openbao` user with the server environment, one PIN login. A failure stops the run before OpenBao retries the seal. Needs `opensc` and `openbao_seal.pkcs11` with `lib`, `key_id`, `slot` or `token_label`. Skipped on a rerun with no change |
| `openbao_service_start_limit_interval_sec`, `openbao_service_start_limit_burst` | `60`, `3` | systemd start limits; they count manual starts too, so a low burst refuses ordinary restarts |

### TLS

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `openbao_tls_self_signed` | `true` | Generate an ECDSA P-384 key and a self-signed certificate on the host |
| `openbao_tls_common_name` | the host's FQDN | Certificate subject |
| `openbao_tls_subject_alt_names` | `[]` | `IP:...` / `DNS:...`; `127.0.0.1`, `localhost` and the host of `openbao_api_addr` are always added |
| `openbao_tls_valid_days` | `3650` | Validity |
| `openbao_tls_dir` | `/opt/openbao/tls` | Directory of the generated key (0600) and certificate (0644); the directory is 0755 |
| `openbao_tls_cert_file`, `openbao_tls_key_file` | under `openbao_tls_dir` | Paths (bring your own with `openbao_tls_self_signed: false`) |
| `openbao_tls_ca_file` | the certificate itself; in a cluster, the bundle | CA that clients and the role trust (`BAO_CACERT`, every API call): your CA bundle when the certificate is CA-issued |

`/etc/openbao/client.env` sets `BAO_ADDR` and `BAO_CACERT` for local use: `. /etc/openbao/client.env && bao status`.

### Raft snapshots

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `openbao_backup_enabled` | `false` | A systemd timer (`openbao-snapshot.timer`) running `openbao-raft-snapshot` |
| `openbao_backup_dir` | `/var/backups/openbao` | Snapshots, root 0700 |
| `openbao_backup_schedule` | `daily` | systemd `OnCalendar` |
| `openbao_backup_keep` | `7` | The newest kept |
| `openbao_backup_token_period` | `604800` | The snapshot token's period (seconds); each run renews it |

The post-init part creates the `openbao-snapshot` policy (`sys/storage/raft/snapshot`, read) and token role, then one periodic orphan token per host with snapshots enabled, in `/etc/openbao/backup.token` (root, 0400). It keeps a token while it is valid and replaces an expired one. A snapshot is encrypted by the seal: restoring it needs the same seal or the unseal keys. In a cluster, enable it on one member (any member: a standby forwards the request).

### Post-init (`tasks_from: configure`)

| Variable | Meaning |
| -------- | ------- |
| `openbao_root_token` | Given at run time only (`-e` or `vars_prompt`); the part stops without it |
| `openbao_addr` | API address used on the host (default: the listener, loopback for a wildcard), `https://host:port` |
| `openbao_auth_methods` | `{path, type, description?, config?}`; `config` is the mount tuning (`default_lease_ttl`, `max_lease_ttl`, `listing_visibility`, ...) |
| `openbao_secrets_engines` | `{path, type, description?, config?, options?}`; `options` values are strings (`{version: "2"}` for kv v2); a trailing `/` is ignored |
| `openbao_transit_keys` | `{mount, name, type?, derived?, convergent_encryption?, key_size?, exportable?, allow_plaintext_backup?, auto_rotate_period?, deletion_allowed?, min_decryption_version?, min_encryption_version?}`; `type` (default `aes256-gcm96`), `derived`, `convergent_encryption` and `key_size` cannot change once created |
| `openbao_policies` | `{name, rules}` (HCL) |
| `openbao_token_roles` | `{name, allowed_policies, ...}`: any token role parameter (`orphan`, `renewable`, `token_period`, `token_explicit_max_ttl`, `token_bound_cidrs`, `token_type`, `token_no_default_policy`, `token_num_uses`, `path_suffix`, ...); a token role has no `token_ttl` (the TTL comes from the token mount) |
| `openbao_api_resources` | `{path, data}`: any other object written with a POST and read back with a GET, e.g. an AppRole role (`auth/approle/role/app`), a Kubernetes auth config (`auth/kubernetes/config`), a userpass user |

Every item takes `state: present` (default) or `absent`: absent disables the mount (its data is destroyed), deletes the key (after allowing it), the policy, the role or the object. An item left out of a list is left alone.

Each item is read first and written only when a given key differs from what the API reads back, so a rerun changes nothing. Two consequences: give durations in seconds (`3600`, not `1h`) and lists as lists, as the API returns them; and a key the API never reads back (a password) is written when the object is created only. A path already enabled with another type stops the run. In a cluster, the writes run once, on the first member in the play. Every task that carries the root token has `no_log`.

## Example: a transit unseal service sealed by an HSM

Values are illustrative: take the plugin archive and binary sha256 from the openbao-plugins release you pin, and the library, token and key names from your HSM.

```yaml
- hosts: unseal
  become: true
  roles:
    - role: cedricfarinazzo.openbao
      openbao_api_addr: https://198.51.100.20:8200
      openbao_tls_subject_alt_names: ["DNS:unseal.example.org"]
      openbao_tls_common_name: unseal.example.org
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
          # On a PIV token several objects share one CKA_ID: give the private key's label too
          key_id: "01"
          key_label: unseal-key
          rsa_oaep_hash: sha256
      openbao_environment:
        BAO_HSM_PIN: "{{ lookup('env', 'BAO_HSM_PIN') }}"
      openbao_environment_required: [BAO_HSM_PIN]
      # A PIN with a retry counter: no automatic restart, alert on the service instead
      openbao_service_restart: "no"
      openbao_audit_devices:
        - {type: file, path: file, options: {file_path: /var/log/openbao/audit.log}}
      openbao_backup_enabled: true
```

Then `bao operator init -recovery-shares=5 -recovery-threshold=3` on the host, then the post-init part:

```yaml
- hosts: unseal
  become: true
  vars_prompt:
    - name: openbao_root_token
      prompt: Root token
      private: true
  tasks:
    - ansible.builtin.include_role:
        name: cedricfarinazzo.openbao
        tasks_from: configure
      vars:
        openbao_api_addr: https://198.51.100.20:8200
        openbao_backup_enabled: true
        openbao_secrets_engines: [{path: transit, type: transit}]
        openbao_transit_keys: [{mount: transit, name: unseal}]
        openbao_policies:
          - name: unseal
            rules: |
              path "transit/encrypt/unseal" { capabilities = ["update"] }
              path "transit/decrypt/unseal" { capabilities = ["update"] }
        openbao_token_roles:
          - {name: unseal, allowed_policies: [unseal], token_period: 3600, orphan: true}
```

## Example: a three-node raft cluster

```yaml
# inventory: group "bao" with bao-1, bao-2, bao-3
- hosts: bao
  become: true
  roles:
    - role: cedricfarinazzo.openbao
      openbao_cluster_group: bao
      openbao_api_addr: "https://{{ inventory_hostname }}.example.org:8200"
      openbao_seal: {awskms: {region: eu-west-3, kms_key_id: "<key id>"}}
      openbao_log_format: json
      openbao_listener_options:
        telemetry: {unauthenticated_metrics_access: true}
      openbao_telemetry: {prometheus_retention_time: 24h, disable_hostname: true}
```

Then `bao operator init` on one node; the others join through `retry_join` and unseal through the seal. The post-init part (same `hosts: bao`) writes once:

```yaml
        openbao_auth_methods:
          - {path: approle, type: approle, config: {default_lease_ttl: 3600, max_lease_ttl: 86400}}
        openbao_secrets_engines:
          - {path: kv, type: kv, options: {version: "2"}}
        openbao_policies:
          - {name: app, rules: 'path "kv/data/app/*" { capabilities = ["read"] }'}
        openbao_api_resources:
          - {path: auth/approle/role/app, data: {token_policies: [app], token_ttl: 1800, secret_id_ttl: 0}}
```

## Out of scope, on purpose

- **Init and unseal keys:** the role never runs `bao operator init` or submits unseal keys, so the keys and the root token never reach the controller.
- **Firewall:** open 8200 (and 8201 between cluster members) with the host's firewall role.
- **A binary or zip install:** the signed packages are the trust anchor.

## Testing

`./run-tests.sh debian13` (or `all`, in parallel); `./run-tests.sh -s cluster debian13` for the cluster.

- **default** (Debian 12/13, Ubuntu 24.04/26.04, Rocky Linux 9/10): SoftHSM as a stand-in HSM with the real `kms-pkcs11` plugin. The role stops on an unset required variable and on a wrong plugin checksum with nothing installed; `openbao_service_start: false` installs an older release without starting it; a wrong PIN is stopped by the OAEP check; converge upgrades the held package and starts it once; then init (3 recovery shares, threshold 2) and post-init. Verify checks TLS 1.3 only, metrics without a token, JSON logs, the file audit log and its rotation, the tuning and roles read back, a create, change and removal of every kind of object, a refused change of a create-only field, two snapshots kept of three, a periodic token doing transit and nothing else, and a restart unsealing again through the seal. The idempotence step reruns install, init and post-init: nothing changes. SoftHSM 2.6 does RSA-OAEP with SHA-1 only, so the scenario uses `rsa_oaep_hash: sha1`.
- **cluster** (Debian 13): three nodes on one network with a static seal. Each trusts the others' certificates through the bundle, they join by `retry_join` and unseal, three voters, a write on one node read on another, post-init written once, snapshots taken from a standby with its own token.

## License

MIT
