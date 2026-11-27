#!/bin/bash
# The same as rig.sh (the original rigm.sh differed only in letting EXT name the extension folder; rig.sh does that too).
exec bash "$(cd "$(dirname "$0")" && pwd)/rig.sh" "$@"
