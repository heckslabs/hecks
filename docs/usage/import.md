# Import — Reverse Engineer a Rails App

Extract a Hecks domain definition from an existing Rails app.

## Full Import (Schema + Models)

```bash
hecks import rails /path/to/rails/app
```

Reads `db/schema.rb` for structure and `app/models/*.rb` for behavior:
- Tables → aggregates
- Columns → typed attributes (String, Integer, Float, Boolean, Date, DateTime, JSON)
- Foreign keys → `reference_to("Aggregate")`
- `validates` → validation rules
- `enum` → enum constraints
- AASM state machines → lifecycle definitions
- Auto-generates a `Create` command per aggregate

## Schema Only

```bash
hecks import schema /path/to/db/schema.rb
```

Extracts structure without model enrichment. Use this when you don't have access to the model files or just want the data shape.

## Options

```bash
hecks import rails /path/to/app --preview        # Print DSL without writing
hecks import rails /path/to/app -o my_domain.rb  # Custom output path
hecks import rails /path/to/app --name Blog      # Override domain name
```

## Example

Given a Rails app with:

```ruby
# db/schema.rb
create_table "posts" do |t|
  t.string "title"
  t.text "body"
  t.references "author", foreign_key: true
  t.string "status"
  t.timestamps
end

# app/models/post.rb
class Post < ApplicationRecord
  belongs_to :author
  validates :title, presence: true
  enum status: { draft: 0, published: 1 }
end
```

Running `hecks import rails .` produces:

```ruby
Hecks.domain "MyApp" do
  aggregate "Post" do
    attribute :title, String
    attribute :body, String
    attribute :author_id, reference_to("Author")
    attribute :status, String, enum: ["draft", "published"]
    validation :title, {:presence=>true}

    command "CreatePost" do
      attribute :title, String
      attribute :body, String
      attribute :status, String
    end
  end
end
```

## What Gets Skipped

- Rails internal tables: `schema_migrations`, `ar_internal_metadata`, `active_storage_*`, `action_text_*`
- Auto-managed columns: `id`, `created_at`, `updated_at`
- `has_many :through` associations (join tables)
