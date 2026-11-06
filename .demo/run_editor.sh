#!/bin/zsh
source /Users/christopheryoung/Projects/hecks-editor-demo/.demo/env.sh
cd $DEMO/editor
export PORT=48420 NEWSROOM_DOMAIN_SERVICE_URL=$HOST_URL HECKS_SESSION_COOKIE=newsroom_session
exec node src/server.ts
