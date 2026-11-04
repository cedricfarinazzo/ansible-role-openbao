# Ansible role: OpenBao

[![CI](https://github.com/cedricfarinazzo/ansible-role-openbao/actions/workflows/ci.yml/badge.svg)](https://github.com/cedricfarinazzo/ansible-role-openbao/actions/workflows/ci.yml)

An [OpenBao](https://openbao.org) server from the official deb package, set up in two parts:

1. **Install and seal** (`main`): exact version from `pkgs.openbao.org` (repository key fingerprint pinned), external plugins downloaded with their checksums checked **before anything is installed**, a seal stanza (auto-unseal through a KMS plugin such as PKCS#11, or Shamir keys), raft storage, a self-signed TLS certificate generated on the host, and a root-only environment file for secrets such as an HSM PIN.
2. **Post-init** (`tasks_from: configure`): secrets engines, transit keys, ACL policies and token roles, with a root token given at run time and never stored.

`bao operator init` runs between the two, by hand: its output (recovery keys, root token) never passes through Ansible.

## Supported platforms

| Distribution | Versions |
| ------------ | -------- |
| Debian | 12 (bookworm), 13 (trixie) |
| Ubuntu | 24.04 (noble), 26.04 (resolute) |

amd64 and arm64 (the OpenBao repository and the openbao-plugins releases ship both).

## Requirements

- Ansible 2.15+ and the `community.crypto` collection (`requirements.yml`).
- The host reaches `pkgs.openbao.org`, `openbao.org` and the plugin URLs.

## Role variables

### Install

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `openbao_version` | `2.7.2` | Exact version; the package is held at it, and a new value upgrades it |
| `openbao_apt_repo_url` | `https://pkgs.openbao.org/deb` | apt repository |
| `openbao_apt_key_url` | OpenBao's 2024 key | Repository key |
| `openbao_apt_key_fingerprint` | `66D15FDD…53E6D0` | The key must be this one, alone, or nothing is installed |
| `openbao_packages_extra` | `[]` | More packages, e.g. `[pcscd, ykcs11, opensc]` for a YubiKey |
| `openbao_user_groups` | `[]` | Extra groups for the `openbao` user (e.g. `softhsm`) |
| `openbao_pcsc_access` | `false` | polkit rule letting the `openbao` user talk to `pcscd` (installs `polkitd`) |
| `openbao_token_script` | `false` | Install `openbao-token-create <role>` (with the install part): prints one token from a token role, the caller's token from `BAO_TOKEN` or a silent prompt |

### Plugins

`openbao_plugins`: a list, each with `type` (`auth`, `database`, `kms`, `secret`), `name`, `version` (`vX.Y.Z`), `url` (a `.tar.gz` release archive), `checksum` (its sha256), `binary` (the file in the archive), `binary_sha256` (the binary's sha256, rechecked by OpenBao before each start) and optional `args` and `env`. They land in `openbao_plugin_directory` (`/opt/openbao/plugins`) and in the configuration as `plugin "<type>" "<name>"` stanzas.

### Server

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `openbao_api_addr` | (required) | Address clients use, e.g. `https://192.0.2.10:8200` |
| `openbao_listener_address` | `0.0.0.0:8200` | TCP listener (TLS always on) |
| `openbao_cluster_addr` | `https://127.0.0.1:8201` | Raft cluster address |
| `openbao_cluster_listen_address` | `127.0.0.1:8201` | Where the cluster port listens (loopback for one node) |
| `openbao_storage` | raft in `/opt/openbao/data` | One storage backend |
| `openbao_seal` | `{}` | One seal stanza, e.g. `{pkcs11: {...}}`; `{}` keeps Shamir keys |
| `openbao_ui` | `false` | Web UI |
| `openbao_config_extra` | `{}` | Merged last into the configuration |
| `openbao_environment` | `{}` | `NAME: value` for the server, in `/etc/openbao/openbao.env` (root, 0400); never logged |
| `openbao_environment_required` | `[]` | Names that must be set and non-empty, or the role stops before any change |

The configuration is written as JSON (valid OpenBao configuration) to `/etc/openbao/openbao.hcl` and checked with `bao operator validate-config`.

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
| `openbao_tls_subject_alt_names` | `[]` | `IP:...` / `DNS:...`; `127.0.0.1` and `localhost` are always added |
| `openbao_tls_valid_days` | `3650` | Validity |
| `openbao_tls_dir` | `/opt/openbao/tls` | Directory of the generated key (0600) and certificate (0644); the directory is 0755 |
| `openbao_tls_cert_file`, `openbao_tls_key_file` | under `openbao_tls_dir` | Paths (bring your own with `openbao_tls_self_signed: false`) |
| `openbao_tls_ca_file` | the certificate itself | CA that clients and the role trust (`BAO_CACERT`, every API call): your CA bundle when the certificate is CA-issued |

Clients pin the certificate itself as their CA. `/etc/openbao/client.env` sets `BAO_ADDR` and `BAO_CACERT` for local use: `. /etc/openbao/client.env && bao status`.

### Post-init (`tasks_from: configure`)

| Variable | Meaning |
| -------- | ------- |
| `openbao_root_token` | Given at run time only (`-e` or `vars_prompt`); the part stops without it |
| `openbao_addr` | API address used on the host (default: the listener, loopback for a wildcard), `https://host:port` |
| `openbao_secrets_engines` | `{path, type, description?}`; a trailing `/` is ignored; a path already mounted with another type stops the run |
| `openbao_transit_keys` | `{mount, name, type?}` (default `aes256-gcm96`) |
| `openbao_policies` | `{name, rules}` (HCL) |
| `openbao_token_roles` | `{name, allowed_policies, period?, orphan?, renewable?}`; `period` in seconds |

Every task that carries the root token has `no_log`. Each item is created or updated only when it differs, so a rerun changes nothing.

## Example: a transit unseal service sealed by an HSM

Values are illustrative: take the plugin archive and binary sha256 from the openbao-plugins release you pin, and the library, token and key names from your HSM.

```yaml
- hosts: unseal
  become: true
  roles:
    - role: cedricfarinazzo.openbao
      openbao_api_addr: https://198.51.100.20:8200
      openbao_tls_subject_alt_names: ["IP:198.51.100.20", "DNS:unseal.example.org"]
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
        openbao_secrets_engines: [{path: transit, type: transit}]
        openbao_transit_keys: [{mount: transit, name: unseal}]
        openbao_policies:
          - name: unseal
            rules: |
              path "transit/encrypt/unseal" { capabilities = ["update"] }
              path "transit/decrypt/unseal" { capabilities = ["update"] }
        openbao_token_roles:
          - {name: unseal, allowed_policies: [unseal], period: 3600, orphan: true}
```

## Testing

`./run-tests.sh debian13` (or `all`, in parallel). The Molecule scenario uses SoftHSM as a stand-in HSM with the real `kms-pkcs11` plugin: the role stops on an unset required variable and on a wrong plugin checksum with nothing installed; `openbao_service_start: false` installs an older release without starting or enabling it; converge upgrades the held package and starts it once; then init (3 recovery shares, threshold 2), post-init twice (the second changes nothing), a periodic token from the token script does transit encrypt and decrypt and nothing else, and a restart unseals again through the seal alone. SoftHSM 2.6 does RSA-OAEP with SHA-1 only, so the scenario uses `rsa_oaep_hash: sha1`.

## License

MIT
