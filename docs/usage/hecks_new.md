# hecks new — Scaffold a Project

Create a complete Hecks project in one command.

## Usage

```
$ hecks new banking

Created banking/
  hecks_domain.rb
  app.rb
  Gemfile
  spec/spec_helper.rb
  .gitignore
  .rspec

Get started:
  cd banking
  bundle install
  ruby app.rb
```

## What it generates

**hecks_domain.rb** — starter domain definition:
```ruby
Hecks.domain "Banking" do
  aggregate "Example" do
    attribute :name, String

    command "CreateExample" do
      attribute :name, String
    end
  end
end
```

**app.rb** — one-line boot:
```ruby
require "hecks"

app = Hecks.boot(__dir__)

# Start building:
#   Example.create(name: "Hello")
#   Example.all
```

## Hecks.boot

`Hecks.boot(__dir__)` replaces the manual load/validate/build/require/wire sequence:

```ruby
# Before (10 lines):
domain_file = File.join(__dir__, "hecks_domain.rb")
domain = eval(File.read(domain_file), nil, domain_file, 1)
Hecks.validate(domain)
output = Hecks.build(domain, output_dir: __dir__)
$LOAD_PATH.unshift(File.join(output, "lib"))
require "banking_domain"
app = Hecks::Services::Runtime.new(domain)

# After (1 line):
app = Hecks.boot(__dir__)
```

`Hecks.boot` finds `hecks_domain.rb`, validates, builds the gem, loads it, and returns a Runtime.

## Running

```ruby
require "hecks"
app = Hecks.boot(__dir__)

Example.create(name: "Widget")
Example.create(name: "Gadget")
Example.count  # => 2
Example.all.each { |e| puts e.name }
```

```
Widget
Gadget
```
