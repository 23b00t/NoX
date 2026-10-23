#!/usr/bin/env bash
# Pack/unpack round trip for the archive formats yazi handles in the VMs
# (compress plugin packs, 7zz extracts). Run in a VM: ssh <vm> bash -s < tests/archive-roundtrip.sh
set -u
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
cd "$d" || exit 1
mkdir -p src/sub
echo hallo >src/a.txt
head -c 200000 /dev/urandom >src/b.bin
echo tief >src/sub/c.txt

fail=0
result() {
  if diff -r src x/src >/dev/null 2>&1; then
    printf '%-8s ok\n' "$1"
  else
    printf '%-8s FEHLER\n' "$1"
    fail=1
  fi
  rm -rf x
}

for f in zip 7z; do
  7zz a -bso0 -bsp0 "t.$f" src && mkdir x && 7zz x -bso0 -bsp0 -ox "t.$f"
  result "$f"
done

# tar.*: pack with tar + compressor (like the compress plugin), unpack with
# 7zz in two steps (decompress, then the inner tar) like yazi's extractor
for f in tar tar.gz tar.xz tar.zst tar.bz2; do
  case "$f" in
    tar) tar -cf "t.$f" src ;;
    tar.gz) tar -czf "t.$f" src ;;
    tar.xz) tar -cJf "t.$f" src ;;
    tar.zst) tar --zstd -cf "t.$f" src ;;
    tar.bz2) tar -cjf "t.$f" src ;;
  esac
  mkdir x
  if [ "$f" = tar ]; then
    7zz x -bso0 -bsp0 -ox "t.$f"
  else
    7zz x -bso0 -bsp0 -so "t.$f" | (cd x && 7zz x -bso0 -bsp0 -si -ttar)
  fi
  result "$f"
done

# RAR: extracting needs the unfree RAR codec in 7zz, packing a proprietary rar
if 7zz i | grep -qi 'rar'; then
  echo "rar      entpacken möglich (7zz mit RAR-Codec), packen nicht (kein rar)"
else
  echo "rar      nicht unterstützt (7zz ohne RAR-Codec)"
fi
exit "$fail"
