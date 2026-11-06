#!/bin/zsh
source /Users/christopheryoung/Projects/hecks-editor-demo/.demo/env.sh
export HECKS_SERVE_MODE=1 PORT=48410 HECKS_DOMAIN=MarlowFinch HECKS_SCHEMA=marlow_editor_demo
export HECKS_WASM_PATH=$DEMO/stage/marlow.wasm HECKS_IR_PATH=$DEMO/stage/marlow.ir.json
export DATABASE_URL=postgres://$USER@localhost:5432/marlow_editor_demo HECKS_SESSION_COOKIE=newsroom_session
exec $DEMO/stage/marlow-host
