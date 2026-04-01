# Domain Interviewer

Conversational onboarding that walks you through defining a domain interactively. Instead of writing DSL by hand, the interviewer asks questions and generates a valid Bluebook file.

## Usage

```sh
hecks interview
```

## Example Session

```
$ hecks interview
Welcome to Hecks! Let's build your domain together.

Domain name: Pizzas

Now let's define your aggregates (the core entities in your domain).
Press Enter with a blank name when you're done.
Aggregate name (blank to finish): Pizza
  Attributes for Pizza (format: name:Type, blank to finish):
    attribute: name:String
    attribute: size:String
    attribute:
  Commands for Pizza (blank to finish):
    command: CreatePizza
    command: UpdatePizza
    command:
Aggregate name (blank to finish): Order
  Attributes for Order (format: name:Type, blank to finish):
    attribute: quantity:Integer
    attribute:
  Commands for Order (blank to finish):
    command: PlaceOrder
    command:
Aggregate name (blank to finish):

--- Domain Summary ---
Domain: Pizzas
  Aggregate: Pizza
    - name: String
    - size: String
    > CreatePizza
    > UpdatePizza
  Aggregate: Order
    - quantity: Integer
    > PlaceOrder
---------------------
Write this domain? [Y/n]: Y
Created PizzasBluebook
Created verbs.txt

Next steps:
  hecks validate          # check your domain
  hecks build             # generate the domain gem
  hecks console           # edit interactively
```

## Generated Output

The interviewer creates a standard Bluebook file:

```ruby
Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :name, String
    attribute :size, String

    command "CreatePizza" do
      attribute :name, String
      attribute :size, String
    end

    command "UpdatePizza" do
      attribute :name, String
      attribute :size, String
    end
  end

  aggregate "Order" do
    attribute :quantity, Integer

    command "PlaceOrder" do
      attribute :quantity, Integer
    end
  end
end
```

## Options

- `--force` — overwrite existing Bluebook without prompting

## Notes

- Blank domain name is rejected; you'll be re-prompted
- Attribute format is `name:Type` where Type defaults to String if omitted
- Command attributes are auto-populated from the aggregate's attributes
- Events are auto-inferred from command names (CreatePizza -> CreatedPizza)
