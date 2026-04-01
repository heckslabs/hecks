# Hot Reload in Serve Mode

Watch for domain source changes and automatically reload routes without
restarting the server.

## Usage

```bash
hecks serve --watch
hecks serve pizzas_domain --watch
hecks serve pizzas_domain --watch --live
```

When `--watch` is active, Hecks polls the domain source directory every
second for Ruby file changes. When a change is detected, the Bluebook is
re-evaluated, the domain IR is rebuilt, and routes are swapped in — all
without dropping existing connections or restarting WEBrick.

## How It Works

1. On startup, the server snapshots mtime values for all `.rb` files in the
   domain source directory (derived from `domain.source_path`).
2. A background thread polls every second (configurable via `watch_interval:`).
3. When any file is added, removed, or modified, the server:
   - Re-evaluates the Bluebook source via `Kernel.load`
   - Rebuilds the Runtime and route table
   - Swaps `@domain`, `@app`, and `@routes` under a Mutex
4. Requests in flight complete against the old routes. New requests use the
   updated routes.

## Terminal Output

```
Hecks serving Pizzas on http://localhost:9292

  GET    /pizzas
  POST   /pizzas
  ...
  Watching /path/to/pizzas_domain for changes...

[hecks] Domain reloaded at 14:32:07
[hecks] Domain reloaded at 14:33:15
```

## Error Handling

If a reload fails (syntax error in the Bluebook, validation failure, etc.),
the server prints a warning and continues serving the previous version:

```
[hecks] Reload failed: undefined method `foo' for ...
```

## Programmatic Use

```ruby
require "hecks_serve"

domain = Hecks.domain("Pizzas") { ... }
server = Hecks::HTTP::DomainServer.new(domain, watch: true, watch_interval: 2)
server.run
```

The `DomainWatcher` can also be used independently:

```ruby
watcher = Hecks::HTTP::DomainWatcher.new("/path/to/domain", interval: 1) do
  puts "Files changed!"
end
watcher.start
# ... later
watcher.stop
```

## Notes

- No gem dependencies added — uses stdlib `Dir[]` + `File.mtime` polling
- Thread-safe: a Mutex protects route access during reload
- Only `.rb` files are monitored; non-Ruby files are ignored
- The watcher requires `domain.source_path` to be set (automatic when loaded
  from a Bluebook file via the CLI)
