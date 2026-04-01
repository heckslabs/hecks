# `hecks extract` — Domain Extractor

Auto-detects a project's type and generates a Hecks domain definition.

## Usage

```bash
# Extract from a Rails app (auto-detects schema.rb)
hecks extract /path/to/rails/app

# Preview without writing
hecks extract /path/to/rails/app --preview

# Specify output file and domain name
hecks extract /path/to/app --output MyDomain --name Blog
```

## How It Works

The extractor checks the given directory for `db/schema.rb`:

- **With schema.rb**: Uses the full Rails import pipeline (SchemaParser + ModelParser + DomainAssembler). Column types, foreign keys, validations, enums, and state machines are all captured.
- **Without schema.rb**: Falls back to model-only extraction (ModelParser + ModelOnlyAssembler). Derives structure from `belongs_to`, `has_many`, validations, enums, and AASM state machines.

## Options

| Flag        | Default      | Description                              |
|-------------|--------------|------------------------------------------|
| `--output`  | `Bluebook`   | Output file path                         |
| `--preview` | `false`      | Print DSL to stdout without writing      |
| `--name`    | *(inferred)* | Domain name (defaults to directory name) |

## Examples

### Rails app with schema

```bash
$ hecks extract ~/Projects/blog --preview --name Blog

Hecks.domain "Blog" do
  aggregate "Post" do
    attribute :title, String
    attribute :body, String
    reference_to "Author"
    validation :title, {:presence=>true}

    lifecycle :status, default: "draft" do
      transition "PublishPost" => "published"
    end

    command "CreatePost" do
      attribute :title, String
      attribute :body, String
    end
  end

  aggregate "Author" do
    attribute :name, String
    attribute :email, String

    command "CreateAuthor" do
      attribute :name, String
      attribute :email, String
    end
  end
end
```

### Models-only project (no schema.rb)

```bash
$ hecks extract ~/Projects/service --preview --name Ordering

Hecks.domain "Ordering" do
  aggregate "Order" do
    reference_to "Customer"
    list_of "LineItem"
    attribute :status, String, enum: ["pending", "confirmed", "shipped"]

    lifecycle :state, default: "pending" do
      transition "ConfirmOrder" => "confirmed"
      transition "ShipOrder" => "shipped"
    end
  end
end
```

## Programmatic API

```ruby
# Auto-detect project type
dsl = Hecks::Import.from_directory("/path/to/app", domain_name: "Blog")

# Model-only extraction
dsl = Hecks::Import.from_models("/path/to/models", domain_name: "Blog")
```
