# Command Bus Port (HTTP Adapter Boundary)

The `Hecks::HTTP::CommandBusPort` is the explicit boundary between HTTP routes
and the domain layer. All mutations flow through the `CommandBus` middleware
pipeline. All reads are validated against a safety whitelist before calling
public methods on aggregate classes.

## Architecture

```
HTTP Request
    |
    v
RouteBuilder (routes)
    |
    v
CommandBusPort          <-- new boundary
    |           |
    v           v
 dispatch()   read()
    |           |
    v           |
CommandBus      |     (middleware pipeline)
    |           |
    v           v
   Domain Layer
```

## Usage

```ruby
# Build a port from a command bus
port = Hecks::HTTP::CommandBusPort.new(command_bus: app.command_bus)

# Mutations go through the command bus pipeline
port.dispatch("CreatePizza", name: "Margherita")

# Reads call public methods after safety validation
port.read(PizzaClass, "Pizza", :all)
port.read(PizzaClass, "Pizza", :find, some_id)
```

## Port Middleware

Port-level middleware fires before the command reaches the bus. This is useful
for HTTP-specific concerns (rate limiting, request logging, authentication)
that should not live in the domain command bus.

```ruby
port.use(:http_auth) do |command_name, attrs, next_fn|
  raise "Unauthorized" unless current_user_authorized?(command_name)
  next_fn.call
end

port.use(:request_timing) do |command_name, attrs, next_fn|
  start = Time.now
  result = next_fn.call
  puts "#{command_name} took #{Time.now - start}s"
  result
end
```

Middleware can short-circuit by not calling `next_fn`:

```ruby
port.use(:blocker) do |command_name, attrs, next_fn|
  :blocked  # command bus never reached
end
```

## Read Safety

The port blocks dangerous method calls via `FORBIDDEN_READS`:

```ruby
port.read(klass, "Pizza", :eval)    # => raises DispatchNotAllowed
port.read(klass, "Pizza", :system)  # => raises DispatchNotAllowed
port.read(klass, "Pizza", :send)    # => raises DispatchNotAllowed
```

Safe reads pass through to `public_send`:

```ruby
port.read(klass, "Pizza", :all)     # => klass.public_send(:all)
port.read(klass, "Pizza", :find, id) # => klass.public_send(:find, id)
```

## Integration

Both `DomainServer` and `RpcServer` build a `CommandBusPort` at boot and
thread it through to route handlers. No HTTP handler calls the domain directly.
