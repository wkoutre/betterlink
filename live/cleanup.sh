#!/bin/bash
# usage: cleanup.sh: stops what the rig left running (only processes of the throwaway profile and the rig's own app) and removes the temporary folders.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
cleanup; echo "cleaned $W/run"
