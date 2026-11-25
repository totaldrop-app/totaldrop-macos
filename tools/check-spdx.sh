#!/bin/sh
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later

# Every hand-written source file states its copyright and license in its
# first six lines. REUSE.toml covers files that cannot carry comments, so
# `reuse lint` alone would not catch a source file missing its header.
set -eu
cd "$(dirname "$0")/.."
missing=$(git ls-files '*.rs' '*.swift' '*.c' '*.h' '*.sh' '*.py' '*.rb' |
  # REUSE-IgnoreStart (the patterns below are not this file's tags)
  while IFS= read -r f; do
    head -n 6 "$f" | grep -q 'SPDX-FileCopyrightText:' &&
      head -n 6 "$f" | grep -q 'SPDX-License-Identifier:' ||
      echo "$f"
  done)
# REUSE-IgnoreEnd
if [ -n "$missing" ]; then
  echo "These source files have no SPDX lines in their top 6 lines:"
  echo "$missing"
  exit 1
fi
echo "SPDX lines ok"
