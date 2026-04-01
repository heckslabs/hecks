# = HecksCli
#
# Entry point for the Hecks command-line interface. Loads the Thor-based
# CLI that provides domain lifecycle commands including:
#
# - +hecks init+ -- Initialize a new Hecks domain project
# - +hecks build+ -- Compile a domain definition into generated Ruby classes
# - +hecks serve+ -- Start an HTTP domain server
# - +hecks console+ -- Open an interactive session with a loaded domain
# - +hecks mcp+ -- Start an MCP (Model Context Protocol) server for AI agents
# - +hecks validate+ -- Lint a domain definition for errors and warnings
# - +hecks dump+ -- Serialize a domain to JSON or YAML
# - +hecks gem+ -- Package a domain as a Ruby gem
#
# == Usage
#
#   require "hecks_cli"
#   Hecks::CLI.start(ARGV)
#
# This is a separate entry point (future gem: +hecks_cli+) to keep the
# CLI dependencies (Thor) isolated from the core framework.
#
require_relative "hecks_cli/cli"
require_relative "hecks_cli/import"
require_relative "hecks_cli/architecture_tour"
