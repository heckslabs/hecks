# hecks_modules

DSL, registries, and discovery infrastructure for Hecks modules.

## ModuleDSL

Declare lazily-initialized registries in any Hecks mixin:

```ruby
module MyRegistryMethods
  extend Hecks::ModuleDSL

  lazy_registry :widgets                     # defaults to {}
  lazy_registry(:rules) { [] }              # custom default via block
  lazy_registry(:internals, private: true)  # private accessor
end
```

Registries initialize on first access — no upfront `@var = {}` needed.

## Built-in Registries

All Hecks registries use `lazy_registry`:

```ruby
Hecks.target_registry       # build targets (ruby, static, go, rails)
Hecks.extension_registry    # extension hooks
Hecks.dump_formats          # dump/export formats
Hecks.registered_adapters   # persistence adapter types
Hecks.validation_rules      # domain validation rule classes
Hecks.loaded_domains        # cached loaded domain modules
Hecks.domain_objects        # domain IR objects
```

## Registering Targets

```ruby
Hecks.register_target(:custom) do |domain, **opts|
  MyCustomBuilder.new(domain).build(**opts)
end
```

## Registering Adapters

```ruby
Hecks.register_adapter(:dynamodb)
Hecks.adapter?(:dynamodb)  # => true
```

## Registering Dump Formats

```ruby
Hecks.register_dump_format(:yaml, desc: "YAML export") do |domain, say:|
  File.write("domain.yml", domain.to_yaml)
  say.call("Dumped domain.yml", :green)
end
```
