#!/usr/bin/env bash
# The role's input checks: each bad input fails before anything changes, the good ones pass.
# Runs tasks/validate.yml on two local inventory hosts; needs ansible-playbook on PATH, no host.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/roles"
ln -s "$REPO" "$WORK/roles/openbao"
# Groups: bao (node-a), pair (node-a, node-b), other (node-b); the play runs on node-a unless validate_hosts says
cat > "$WORK/inventory.yml" <<'INV'
all:
  vars:
    ansible_connection: local
    ansible_python_interpreter: auto_silent
    openbao_tls_common_name: bao.example.com
  hosts:
    node-a:
      openbao_api_addr: https://a.example.com:8200
    node-b:
      openbao_api_addr: https://b.example.com:8200
  children:
    bao:
      hosts:
        node-a:
    pair:
      hosts:
        node-a:
        node-b:
    other:
      hosts:
        node-b:
INV
cat > "$WORK/play.yml" <<'PLAY'
- name: Validate openbao inputs
  hosts: "{{ validate_hosts | default('node-a') }}"
  gather_facts: false
  tasks:
    - name: Validate
      ansible.builtin.include_role:
        name: openbao
        tasks_from: validate.yml
PLAY
fails=0
run() { ANSIBLE_ROLES_PATH=$WORK/roles ansible-playbook -i "$WORK/inventory.yml" -e "$1" "$WORK/play.yml" > "$WORK/out" 2>&1; }
good() { if run "$2"; then echo "ok   accepted: $1"; else echo "FAIL rejected a good input: $1" >&2; tail -5 "$WORK/out" >&2; fails=$((fails + 1)); fi; }
# Rejected by an assert, never by a templating crash: that would pass for the wrong reason.
# The environment assert has no_log, so its failure shows as hidden output, not as the assertion.
bad() {
  if run "$2"; then echo "FAIL accepted: $1" >&2; fails=$((fails + 1))
  elif grep -qE '"assertion"|Action failed: |"censored"' "$WORK/out"; then echo "ok   rejected: $1"
  else echo "FAIL failed without an assertion: $1" >&2; grep -m3 -E 'ERROR|fatal' "$WORK/out" >&2; fails=$((fails + 1)); fi
}

# A cluster of node-a and node-b on raft: each cluster case changes one input of it
CLUSTER='"validate_hosts": "node-a:node-b", "openbao_cluster_group": "pair"'
PKCS11='"openbao_seal": {"pkcs11": {"lib": "/usr/lib/softhsm/libsofthsm2.so", "slot": "0", "key_id": "03"}}'
HEX_A=$(printf 'a%.0s' {1..64})
HEX_B=$(printf 'b%.0s' {1..64})
PLUGIN='"type": "kms", "name": "kms-pkcs11", "version": "v0.1.0", "url": "https://example.com/p.tar.gz", "checksum": "'$HEX_A'", "binary": "kms-pkcs11", "binary_sha256": "'$HEX_B'"'

# Install inputs
good "the defaults" '{}'
good "extra packages, groups, pcsc access" '{"openbao_packages_extra": ["softhsm2"], "openbao_user_groups": ["softhsm"], "openbao_pcsc_access": true}'
bad "a version without a patch" '{"openbao_version": "2.7"}'
bad "a version with a trailing newline" '{"openbao_version": "2.7.2\n"}'
bad "a version as a number" '{"openbao_version": 2.7}'
bad "an unsupported family" '{"ansible_facts": {"os_family": "Suse"}}'
bad "a lower-case fingerprint" '{"openbao_gpg_key_fingerprint": "66d15fdd87287219c8e15478d200cd702853e6d0"}'
bad "a 39-character fingerprint" '{"openbao_gpg_key_fingerprint": "66D15FDD87287219C8E15478D200CD702853E6D"}'
bad "a fingerprint with a trailing newline" '{"openbao_gpg_key_fingerprint": "66D15FDD87287219C8E15478D200CD702853E6D0\n"}'
bad "an http apt repository" '{"openbao_apt_repo_url": "http://pkgs.example.com/deb"}'
bad "an http release URL" '{"openbao_release_url": "http://example.com/releases"}'
bad "an http key URL" '{"openbao_gpg_key_url": "http://example.com/key.asc"}'
bad "a space in the apt repository" '{"openbao_apt_repo_url": "https://pkgs.example.com/d eb"}'
bad "a newline in the release URL" '{"openbao_release_url": "https://example.com/rel\neases"}'
bad "a trailing newline in the key URL" '{"openbao_gpg_key_url": "https://example.com/key.asc\n"}'
bad "extra packages as a string" '{"openbao_packages_extra": "softhsm2"}'
bad "groups as a string" '{"openbao_user_groups": "softhsm"}'
bad "pcsc access as a string" '{"openbao_pcsc_access": "yes"}'

# Server inputs
good "an IPv6 API address, SANs, TLS paths, listeners, telemetry" '{"openbao_api_addr": "https://[2001:db8::1]:8200", "openbao_tls_subject_alt_names": ["IP:2001:db8::1", "DNS:*.example.com"], "openbao_tls_dir": "/etc/openbao/tls", "openbao_listener_address": "[::]:8200", "openbao_listener_options": {"tls_min_version": "tls13"}, "openbao_listeners_extra": [{"tcp": {"address": "127.0.0.1:8300"}}], "openbao_telemetry": {"disable_hostname": true}, "openbao_ui": true}'
good "a seal, a previous seal, service ordering" '{'"$PKCS11"', "openbao_seal_previous": {"static": {"current_key_id": "k1"}}, "openbao_service_after": ["pcscd.service"], "openbao_service_before": ["nginx.service"], "openbao_service_restart": "no", "openbao_log_level": "debug", "openbao_log_format": "json"}'
bad "no API address" '{"openbao_api_addr": ""}'
bad "an API address without a scheme" '{"openbao_api_addr": "a.example.com:8200"}'
bad "an API address with a path" '{"openbao_api_addr": "https://a.example.com:8200/v1"}'
bad "an API address with a trailing newline" '{"openbao_api_addr": "https://a.example.com:8200\n"}'
bad "an http cluster address" '{"openbao_cluster_addr": "http://127.0.0.1:8201"}'
bad "a trailing newline in the cluster address" '{"openbao_cluster_addr": "https://127.0.0.1:8201\n"}'
bad "a space in the cluster address" '{"openbao_cluster_addr": "https://127.0.0.1:8201 x"}'
bad "a listener without a port" '{"openbao_listener_address": "0.0.0.0"}'
bad "a listener with a trailing newline" '{"openbao_listener_address": "0.0.0.0:8200\n"}'
bad "two storage backends" '{"openbao_storage": {"raft": {"path": "/a"}, "file": {"path": "/b"}}}'
bad "no storage backend" '{"openbao_storage": {}}'
bad "two seals" '{"openbao_seal": {"pkcs11": {}, "static": {}}}'
bad "two previous seals" '{"openbao_seal_previous": {"pkcs11": {}, "static": {}}}'
bad "a previous seal that is not a mapping" '{"openbao_seal_previous": {"static": "k1"}}'
bad "a previous seal equal to the seal" '{"openbao_seal": {"static": {"current_key_id": "k1"}}, "openbao_seal_previous": {"static": {"current_key_id": "k1"}}}'
bad "extra config as a list" '{"openbao_config_extra": ["x"]}'
bad "ui as a string" '{"openbao_ui": "true"}'
bad "self-signed TLS as a string" '{"openbao_tls_self_signed": "yes"}'
bad "SANs as a string" '{"openbao_tls_subject_alt_names": "DNS:a.example.com"}'
bad "a URI SAN" '{"openbao_tls_subject_alt_names": ["URI:https://a.example.com"]}'
bad "a SAN with a trailing newline" '{"openbao_tls_subject_alt_names": ["DNS:a.example.com\n"]}'
bad "a SAN with an embedded newline" '{"openbao_tls_subject_alt_names": ["DNS:a.example.com\nIP:192.0.2.1"]}'
bad "a validity of 0 days" '{"openbao_tls_valid_days": 0}'
bad "a validity as a string" '{"openbao_tls_valid_days": "365"}'
bad "an empty common name" '{"openbao_tls_common_name": ""}'
bad "a relative TLS dir" '{"openbao_tls_dir": "etc/tls"}'
bad "a certificate path with a space" '{"openbao_tls_cert_file": "/etc/tls/my cert.crt"}'
bad "a key path with a trailing newline" '{"openbao_tls_key_file": "/etc/tls/tls.key\n"}'
bad "a relative CA path" '{"openbao_tls_ca_file": "ca.pem"}'
bad "a plugin dir with an embedded newline" '{"openbao_plugin_directory": "/opt/plugins\n/x"}'
bad "an http client address" '{"openbao_addr": "http://127.0.0.1:8200"}'
bad "a client address without a port" '{"openbao_addr": "https://127.0.0.1"}'
bad "a token script as a string" '{"openbao_token_script": "yes"}'
bad "a cluster listener without a port" '{"openbao_cluster_listen_address": "127.0.0.1"}'
bad "listener options as a list" '{"openbao_listener_options": ["tls_min_version"]}'
bad "extra listeners as a string" '{"openbao_listeners_extra": "tcp"}'
bad "extra listeners as a number" '{"openbao_listeners_extra": 5}'
bad "an extra listener that is not a mapping" '{"openbao_listeners_extra": ["tcp"]}'
bad "an unknown log level" '{"openbao_log_level": "verbose"}'
bad "an unknown log format" '{"openbao_log_format": "text"}'
bad "telemetry as a list" '{"openbao_telemetry": ["x"]}'
bad "service start as a string" '{"openbao_service_start": "yes"}'
bad "an unknown Restart= value" '{"openbao_service_restart": "sometimes"}'
bad "a negative start limit interval" '{"openbao_service_start_limit_interval_sec": -1}'
bad "a start limit burst of 0" '{"openbao_service_start_limit_burst": 0}'
bad "service after as a string" '{"openbao_service_after": "pcscd.service"}'
bad "a service after without a unit type" '{"openbao_service_after": ["pcscd"]}'
bad "a service after with a trailing newline" '{"openbao_service_after": ["pcscd.service\n"]}'
bad "service before as a string" '{"openbao_service_before": "nginx.service"}'
bad "a service before with a space" '{"openbao_service_before": ["nginx.service reboot.target"]}'

# Cluster inputs
good "a one-member cluster" '{"openbao_cluster_group": "bao"}'
good "a two-member cluster, retry_join given" '{'"$CLUSTER"', "openbao_raft_retry_join": [{"leader_api_addr": "https://b.example.com:8200"}]}'
bad "a cluster group as a list" '{"openbao_cluster_group": ["pair"]}'
bad "retry_join as a string" '{"openbao_raft_retry_join": "https://b.example.com:8200"}'
bad "an unknown cluster group" '{"openbao_cluster_group": "missing"}'
bad "a cluster group without this host" '{"validate_hosts": "node-a:node-b", "openbao_cluster_group": "other"}'
bad "a cluster member left out of the play" '{"openbao_cluster_group": "pair"}'
bad "a cluster on file storage" '{'"$CLUSTER"', "openbao_storage": {"file": {"path": "/opt/openbao/data"}}}'
bad "a cluster address on loopback" '{'"$CLUSTER"', "openbao_cluster_addr": "https://127.0.0.1:8201"}'
bad "a cluster listener on loopback" '{'"$CLUSTER"', "openbao_cluster_listen_address": "127.0.0.1:8201"}'
bad "two members with one API address" '{'"$CLUSTER"', "openbao_api_addr": "https://a.example.com:8200"}'

# Audit devices, audit paths and snapshots
good "a file and a syslog device, rotation, snapshots" '{"openbao_audit_devices": [{"type": "file", "path": "file", "options": {"file_path": "/var/log/openbao/audit.log"}}, {"type": "syslog", "path": "syslog/"}], "openbao_audit_logrotate_keep": 30, "openbao_backup_enabled": true, "openbao_backup_keep": 3, "openbao_backup_token_period": 3600}'
good "a file device to stdout" '{"openbao_audit_devices": [{"type": "file", "path": "stdout", "options": {"file_path": "stdout"}}]}'
bad "a device that is not a mapping" '{"openbao_audit_devices": ["file"]}'
bad "an unknown device type" '{"openbao_audit_devices": [{"type": "kafka", "path": "k"}]}'
bad "a device path with a slash inside" '{"openbao_audit_devices": [{"type": "syslog", "path": "a/b"}]}'
bad "a device path with a trailing newline" '{"openbao_audit_devices": [{"type": "syslog", "path": "syslog\n"}]}'
bad "device options as a list" '{"openbao_audit_devices": [{"type": "syslog", "path": "syslog", "options": ["tag"]}]}'
bad "a device option that is not a string" '{"openbao_audit_devices": [{"type": "syslog", "path": "syslog", "options": {"facility": 1}}]}'
bad "a file device without a file path" '{"openbao_audit_devices": [{"type": "file", "path": "file"}]}'
bad "two devices on one path" '{"openbao_audit_devices": [{"type": "syslog", "path": "a"}, {"type": "socket", "path": "a"}]}'
bad "a file device outside the audit log dir" '{"openbao_audit_devices": [{"type": "file", "path": "file", "options": {"file_path": "/tmp/audit.log"}}]}'
bad "a file device in a subdirectory" '{"openbao_audit_devices": [{"type": "file", "path": "file", "options": {"file_path": "/var/log/openbao/sub/audit.log"}}]}'
bad "a file device path with a trailing newline" '{"openbao_audit_devices": [{"type": "file", "path": "file", "options": {"file_path": "/var/log/openbao/audit.log\n"}}]}'
bad "log rotation as a string" '{"openbao_audit_logrotate": "yes"}'
bad "a rotation keep of 0" '{"openbao_audit_logrotate_keep": 0}'
bad "snapshots enabled as a string" '{"openbao_backup_enabled": "yes"}'
bad "a relative snapshot dir" '{"openbao_backup_dir": "backups"}'
bad "a snapshot dir with a trailing newline" '{"openbao_backup_dir": "/var/backups/openbao\n"}'
bad "an empty snapshot schedule" '{"openbao_backup_schedule": ""}'
bad "a snapshot keep of 0" '{"openbao_backup_keep": 0}'
bad "a snapshot token period under an hour" '{"openbao_backup_token_period": 3599}'
bad "snapshots on file storage" '{"openbao_backup_enabled": true, "openbao_storage": {"file": {"path": "/opt/openbao/data"}}}'

# The PKCS#11 OAEP check
good "the OAEP check with a slot" '{"openbao_pkcs11_oaep_check": true, '"$PKCS11"'}'
good "the OAEP check with a token label, SHA-1" '{"openbao_pkcs11_oaep_check": true, "openbao_seal": {"pkcs11": {"lib": "/usr/lib/x.so", "token_label": "bao", "key_id": "0a", "rsa_oaep_hash": "sha1"}}}'
bad "the OAEP check as a string" '{"openbao_pkcs11_oaep_check": "yes"}'
bad "the OAEP check without a PKCS#11 seal" '{"openbao_pkcs11_oaep_check": true, "openbao_seal": {"static": {}}}'
bad "the OAEP check without a library" '{"openbao_pkcs11_oaep_check": true, "openbao_seal": {"pkcs11": {"slot": "0", "key_id": "03"}}}'
bad "the OAEP check with a key id that is not hex" '{"openbao_pkcs11_oaep_check": true, "openbao_seal": {"pkcs11": {"lib": "/usr/lib/x.so", "slot": "0", "key_id": "0x3"}}}'
bad "the OAEP check with a key id ending in a newline" '{"openbao_pkcs11_oaep_check": true, "openbao_seal": {"pkcs11": {"lib": "/usr/lib/x.so", "slot": "0", "key_id": "03\n"}}}'
bad "the OAEP check without a slot or token label" '{"openbao_pkcs11_oaep_check": true, "openbao_seal": {"pkcs11": {"lib": "/usr/lib/x.so", "key_id": "03"}}}'
bad "the OAEP check with MD5" '{"openbao_pkcs11_oaep_check": true, "openbao_seal": {"pkcs11": {"lib": "/usr/lib/x.so", "slot": "0", "key_id": "03", "rsa_oaep_hash": "md5"}}}'

# Plugins
good "a plugin with args and env" '{"openbao_plugins": [{'"$PLUGIN"', "args": ["-v"], "env": ["A=1"]}]}'
bad "a plugin that is not a mapping" '{"openbao_plugins": ["kms-pkcs11"]}'
bad "an unknown plugin type" '{"openbao_plugins": [{'"$PLUGIN"', "type": "storage"}]}'
bad "a plugin name in upper case" '{"openbao_plugins": [{'"$PLUGIN"', "name": "KMS"}]}'
bad "a plugin name with a trailing newline" '{"openbao_plugins": [{'"$PLUGIN"', "name": "kms\n"}]}'
bad "a plugin version without a v" '{"openbao_plugins": [{'"$PLUGIN"', "version": "0.1.0"}]}'
bad "a plugin version with a path" '{"openbao_plugins": [{'"$PLUGIN"', "version": "v0.1.0/../x"}]}'
bad "a plugin version with a trailing newline" '{"openbao_plugins": [{'"$PLUGIN"', "version": "v0.1.0\n"}]}'
bad "an http plugin URL" '{"openbao_plugins": [{'"$PLUGIN"', "url": "http://example.com/p.tar.gz"}]}'
bad "a zip plugin URL" '{"openbao_plugins": [{'"$PLUGIN"', "url": "https://example.com/p.zip"}]}'
bad "a short checksum" '{"openbao_plugins": [{'"$PLUGIN"', "checksum": "abc"}]}'
bad "a binary name with a slash" '{"openbao_plugins": [{'"$PLUGIN"', "binary": "../kms"}]}'
bad "an upper-case binary sha256" '{"openbao_plugins": [{'"$PLUGIN"', "binary_sha256": "'"${HEX_B^^}"'"}]}'
bad "plugin args as a string" '{"openbao_plugins": [{'"$PLUGIN"', "args": "-v"}]}'
bad "plugin env as a string" '{"openbao_plugins": [{'"$PLUGIN"', "env": "A=1"}]}'

# Environment
good "a required variable set" '{"openbao_environment": {"PKCS11_PIN": "1234"}, "openbao_environment_required": ["PKCS11_PIN"]}'
bad "the environment as a list" '{"openbao_environment": ["PKCS11_PIN"]}'
bad "a lower-case variable name" '{"openbao_environment": {"pin": "1234"}}'
bad "a variable name with a trailing newline" '{"openbao_environment": {"PIN\n": "1234"}}'
bad "a value that is not a string" '{"openbao_environment": {"PIN": 1234}}'
bad "a value with an embedded newline" '{"openbao_environment": {"PIN": "1\nOTHER=2"}}'
bad "a value with a CR" '{"openbao_environment": {"PIN": "1\r"}}'
bad "required variables as a string" '{"openbao_environment_required": "PKCS11_PIN"}'
bad "required variables as a number" '{"openbao_environment_required": 5}'
bad "a required variable unset" '{"openbao_environment_required": ["PKCS11_PIN"]}'
bad "a required variable empty" '{"openbao_environment": {"PKCS11_PIN": ""}, "openbao_environment_required": ["PKCS11_PIN"]}'

if [[ $fails -gt 0 ]]; then echo "$fails failed" >&2; exit 1; fi
echo "all passed"
