#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
## tools/scenic_compare.sh A B -- Spec 577 S2a image and manifest comparator.
##
## A and B are scenic render directories or single image files (PNG or WebP). Prints one line:
##   SCENIC_DET manifest_equal=<0|1|na> rms=<float>
## manifest_equal compares the two manifest.json files with generated_epoch removed (na unless both are
## directories); rms is the RMS pixel difference over RGB on a 0..255 scale (directories pair their
## shot-*.png frames by sorted name, or by position when the two hold different shots).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -ne 2 ]; then
    echo "usage: scenic_compare.sh A B" >&2
    exit 2
fi
exec python3 -I "$HERE/scenic/post.py" compare "$1" "$2"
