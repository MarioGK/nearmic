#!/bin/sh
set -eu
bin=${1:-zig-out/bin/nearmic}
ldd "$bin" | awk '
  /linux-vdso/ { next }
  /ld-linux/ { next }
  /libc\.so/ { next }
  /libm\.so/ { next }
  /libpthread\.so/ { next }
  /libdl\.so/ { next }
  { print; bad = 1 }
  END { if (bad) exit 1 }
'
echo "ldd ok: $bin"
