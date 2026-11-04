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
| `openbao_version` | `2.7.2` | Exact version; the package is held at it |
| `openbao_apt_repo_url` | `https://pkgs.openbao.org/deb` | apt repository |
| `openbao_apt_key_url` | OpenBao's 2024 key | Repository key |
| `openbao_apt_key_fingerprint` | `66D15FDD…53E6D0` | The key must be this one, alone, or nothing is installed |
| `openbao_packages_extra` | `[]` | More packages, e.g. `[pcscd, ykcs11, opensc]` for a YubiKey |
| `openbao_user_groups` | `[]` | Extra groups for the `openbao` user (e.g. `softhsm`) |
| `openbao_pcsc_access` | `false` | polkit rule letting the `openbao` user talk to `pcscd` (installs `polkitd`) |

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
| `openbao_service_start_limit_interval_sec`, `openbao_service_start_limit_burst` | `60`, `3` | systemd start limits; they count manual starts too, so a low burst refuses ordinary restarts |

### TLS

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `openbao_tls_self_signed` | `true` | Generate an ECDSA P-384 key and a self-signed certificate on the host |
| `openbao_tls_common_name` | the host's FQDN | Certificate subject |
| `openbao_tls_subject_alt_names` | `[]` | `IP:...` / `DNS:...`; `127.0.0.1` and `localhost` are always added |
| `openbao_tls_valid_days` | `3650` | Validity |
| `openbao_tls_cert_file`, `openbao_tls_key_file` | under `/opt/openbao/tls` | Paths (bring your own with `openbao_tls_self_signed: false`) |

Clients pin the certificate itself as their CA. `/etc/openbao/client.env` sets `BAO_ADDR` and `BAO_CACERT` for local use: `. /etc/openbao/client.env && bao status`.

### Post-init (`tasks_from: configure`)

| Variable | Meaning |
| -------- | ------- |
| `openbao_root_token` | Given at run time only (`-e` or `vars_prompt`); the part stops without it |
| `openbao_secrets_engines` | `{path, type, description?}` |
| `openbao_transit_keys` | `{mount, name, type?}` (default `aes256-gcm96`) |
| `openbao_policies` | `{name, rules}` (HCL) |
| `openbao_token_roles` | `{name, allowed_policies, period?, orphan?, renewable?}`; `period` in seconds |
| `openbao_token_script` | Install `openbao-token-create <role>`: prints one token from a token role (caller's token from `BAO_TOKEN` or a silent prompt) |

Every task that carries the root token has `no_log`. Each item is created or updated only when it differs, so a rerun changes nothing.

## Example: transit auto-unseal service sealed by a YubiKey

```yaml
- hosts: unseal
  become: true
  roles:
    - role: cedricfarinazzo.openbao
      openbao_api_addr: https://192.0.2.10:8200
      openbao_tls_subject_alt_names: ["IP:192.0.2.10"]
      openbao_packages_extra: [pcscd, ykcs11, opensc]
      openbao_pcsc_access: true
      openbao_plugins:
        - type: kms
          name: pkcs11
          version: v0.3.0
          url: https://github.com/openbao/openbao-plugins/releases/download/kms-pkcs11-v0.3.0/openbao-plugin-kms-pkcs11_linux_arm64_v8.tar.gz
          checksum: 9485217db9f2797fec0c56037e64559cdef00e0a3a0c7cc34da6492f402e5d59
          binary: openbao-plugin-kms-pkcs11_linux_arm64_v8
          binary_sha256: 7654edf4f5438e0d798ef6f369526f99722c2c2cab3c83b741539e120348b213
      # PIV slot 9d: ykcs11 gives its data object, certificate and keys CKA_ID 03, so the label picks the key
      openbao_seal:
        pkcs11:
          lib: /usr/lib/aarch64-linux-gnu/libykcs11.so
          slot: "0"
          key_id: "03"
          key_label: Private key for Key Management
          rsa_oaep_hash: sha256
      # No automatic restart: each one would spend a PIN try
      openbao_service_restart: "no"
      openbao_environment:
        BAO_HSM_PIN: "{{ lookup('env', 'BAO_HSM_PIN') }}"
      openbao_environment_required: [BAO_HSM_PIN]
```

Then `bao operator init -recovery-shares=3 -recovery-threshold=2` on the host, then the post-init part:

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
        openbao_api_addr: https://192.0.2.10:8200
        openbao_token_script: true
        openbao_secrets_engines: [{path: transit, type: transit}]
        openbao_transit_keys: [{mount: transit, name: autounseal}]
        openbao_policies:
          - name: autounseal
            rules: |
              path "transit/encrypt/autounseal" { capabilities = ["update"] }
              path "transit/decrypt/autounseal" { capabilities = ["update"] }
        openbao_token_roles:
          - {name: autounseal, allowed_policies: [autounseal], period: 86400, orphan: true}
```

## Testing

`./run-tests.sh debian13` (or `all`, in parallel). The Molecule scenario uses SoftHSM as a stand-in HSM with the real `kms-pkcs11` plugin: the role stops on an unset required variable and on a wrong plugin checksum with nothing installed; `openbao_service_start: false` installs without starting or enabling; then install, init (3 recovery shares, threshold 2), post-init twice (the second changes nothing), a periodic token from the token script does transit encrypt and decrypt and nothing else, and a restart unseals again through the seal alone. SoftHSM 2.6 does RSA-OAEP with SHA-1 only, so the scenario uses `rsa_oaep_hash: sha1`.

## License

MIT
