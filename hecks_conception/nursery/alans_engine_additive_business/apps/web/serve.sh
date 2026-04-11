#!/bin/bash
# Boot Alan's Engine Additive Business — all 16 bounded contexts
HECKS_LIFE="$(dirname "$0")/../../../../hecks_life/target/debug/hecks-life"
BLUEBOOKS="$(dirname "$0")/../../hecks"
PORT=${1:-3100}
echo "Booting Alan's Engine Additive Business on port $PORT..."
$HECKS_LIFE serve "$BLUEBOOKS" $PORT
