#!/bin/sh
exec "$(dirname "$0")/../hecks_life/target/release/hecks-life" boot "$(dirname "$0")" "$@"
