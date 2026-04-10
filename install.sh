#!/usr/bin/env bash
set -e

HECKS_HOME="${HECKS_HOME:-$HOME/.hecks}"
REPO="https://github.com/chrisyoung/hecks.git"

echo "Installing Hecks..."

# Clone or update
if [ -d "$HECKS_HOME" ]; then
  echo "  Updating $HECKS_HOME..."
  git -C "$HECKS_HOME" pull --ff-only 2>/dev/null || git -C "$HECKS_HOME" fetch && git -C "$HECKS_HOME" reset --hard origin/main
else
  echo "  Cloning to $HECKS_HOME..."
  git clone "$REPO" "$HECKS_HOME"
fi

# Bundle
echo "  Installing dependencies..."
cd "$HECKS_HOME"
bundle install --quiet 2>/dev/null || echo "  (bundle install skipped — run manually if needed)"

# Symlink
BIN_DIR="/usr/local/bin"
if [ ! -w "$BIN_DIR" ]; then
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
fi

ln -sf "$HECKS_HOME/bin/hecks" "$BIN_DIR/hecks"
chmod +x "$HECKS_HOME/bin/hecks"

# Make sure bin/hecks always resolves back to HECKS_HOME
export HECKS_HOME

echo ""
echo "Hecks installed!"
echo "  Location: $HECKS_HOME"
echo "  Binary:   $BIN_DIR/hecks"
echo ""

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "^$BIN_DIR$"; then
  echo "Add to your shell profile:"
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi
