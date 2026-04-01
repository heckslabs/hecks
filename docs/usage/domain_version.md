# Domain Versioning — `version:` kwarg

Declare an explicit version for your domain directly in the DSL. The version
propagates to generated artifacts: the Ruby gemspec and the Go server header.

## DSL usage

```ruby
Hecks.domain "Banking", version: "2.1.0" do
  aggregate "Account" do
    attribute :name, String
    command "CreateAccount" do
      attribute :name, String
    end
  end
end
```

## Supported formats

| Format  | Example          | Pattern         |
|---------|------------------|-----------------|
| SemVer  | `"2.1.0"`        | `x.y.z`         |
| CalVer  | `"2026.04.01.1"` | `YYYY.MM.DD.N`  |

`version:` is optional. Omitting it leaves `domain.version` as `nil`.

## Invalid versions raise immediately

```ruby
Hecks.domain "Banking", version: "bad"
# => Hecks::InvalidDomainVersion: Invalid version "bad". Must be semver (x.y.z) or CalVer (YYYY.MM.DD.N).
```

## Accessing the version at runtime

After `Hecks.load_domain(domain)` the loaded module exposes `VERSION` and
`self.version`:

```ruby
domain = Hecks.domain "Banking", version: "2.1.0" do ... end
mod = Hecks.load_domain(domain)
mod.version   # => "2.1.0"
mod::VERSION  # => "2.1.0"
```

## Generated Ruby gemspec

When you run `Hecks.build(domain)` the gemspec picks up the domain version
instead of the default `"0.1.0"`:

```
# banking_domain.gemspec
Gem::Specification.new do |s|
  s.name = "banking_domain"; s.version = "2.1.0"
  ...
end
```

## Generated Go server header

The Go `server.go` file gains a comment header:

```go
// Domain: Banking
// Version: 2.1.0
package server
```
