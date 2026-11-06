#!/usr/bin/env bash
# Rewrites the kms-pkcs11 sums of the Molecule scenario for its molecule_plugin_version: each archive is
# checked against the release's checksums file, then the archive and the unpacked binary are hashed.
set -euo pipefail

f=molecule/default/molecule.yml
ver=$(sed -n 's/^ *molecule_plugin_version: *//p' "$f")
[[ $ver =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "molecule_plugin_version not found in $f" >&2; exit 1; }
base="https://github.com/openbao/openbao-plugins/releases/download/kms-pkcs11-$ver"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT

curl -fsSL "$base/checksums-kms-pkcs11.txt" -o "$d/sums"
for arch in amd64_v1 arm64_v8; do
  a=openbao-plugin-kms-pkcs11_linux_$arch
  curl -fsSL "$base/$a.tar.gz" -o "$d/$a.tar.gz"
  (cd "$d" && grep " $a.tar.gz\$" sums | sha256sum -c --quiet -)
  tar -xzf "$d/$a.tar.gz" -C "$d" "$a"
  archive=$(sha256sum "$d/$a.tar.gz" | cut -d' ' -f1)
  binary=$(sha256sum "$d/$a" | cut -d' ' -f1)
  python3 - "$f" "$arch" "$archive" "$binary" <<'EOF'
import re
import sys

f, arch, archive, binary = sys.argv[1:]
s = open(f).read()
block = re.compile(r"(\n\s+%s:\n\s+archive: )[0-9a-f]{64}(\n\s+binary: )[0-9a-f]{64}" % re.escape(arch))
s, n = block.subn(lambda m: m.group(1) + archive + m.group(2) + binary, s)
if n != 1:
    sys.exit(f"{arch}: no archive/binary block in {f}")
open(f, "w").write(s)
EOF
  echo "$ver $arch: archive $archive, binary $binary"
done
