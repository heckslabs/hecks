# World Goals Onboarding

When creating a new project with `hecks new`, you are prompted to select
world goals interactively. Goals are opt-in ethical validation rules that
check your domain design for alignment with stated values.

## Available goals

| Goal            | What it checks                                       |
|-----------------|------------------------------------------------------|
| `:transparency` | Commands must emit events (no silent mutations)      |
| `:consent`      | User-like aggregate commands must declare actors     |
| `:privacy`      | PII attributes must be `visible: false`              |
| `:security`     | Sensitive aggregates need auth guards                |

## Interactive usage

```
$ hecks new my_app

World goals are opt-in ethical validation rules for your domain.
Available: :transparency, :consent, :privacy, :security
Enter goals (space-separated), or press Enter to skip:
> transparency consent

Created my_app/
  MyAppBluebook   # includes world_goals :transparency, :consent
  app.rb
  ...
```

## Opt-out

Press Enter without typing anything to skip world goals entirely:

```
Enter goals (space-separated), or press Enter to skip:
>
```

The generated Bluebook will not include a `world_goals` line.

## Non-interactive / CI

When stdin is not a TTY (pipes, CI), the prompt is skipped automatically
and no goals are included. You can always add them later by editing the
Bluebook:

```ruby
Hecks.domain "MyApp" do
  world_goals :transparency, :consent

  aggregate "Example" do
    # ...
  end
end
```

## Invalid input

Unrecognized goal names are silently filtered out. Only the four valid
goals (`:transparency`, `:consent`, `:privacy`, `:security`) are kept.
