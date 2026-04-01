# Node.js/TypeScript Target

Generate a complete Node.js/TypeScript Express project from a Hecks domain.

## Usage

```bash
cd examples/pizzas
hecks build --target node
```

This produces `pizzas_static_node/` with a ready-to-run TypeScript project.

## Getting Started

```bash
cd pizzas_static_node
npm install
npm run dev
# => PizzasDomain on http://localhost:3000
```

## Generated Structure

```
pizzas_static_node/
  src/
    aggregates/pizza.ts       # TypeScript interface
    commands/create_pizza.ts  # Command function + event type
    repositories/pizza_repository.ts  # In-memory Map storage
    server.ts                 # Express routes
  package.json
  tsconfig.json
  README.md
```

## Example Output

### Aggregate Interface (src/aggregates/pizza.ts)

```typescript
export interface Pizza {
  id: string;
  name: string;
  description: string;
  toppings: Topping[];
  createdAt: string;
  updatedAt: string;
}
```

### Command Function (src/commands/create_pizza.ts)

```typescript
export interface CreatePizzaAttrs {
  name: string;
  description: string;
}

export interface CreatedPizza {
  type: "CreatedPizza";
  aggregateId: string;
  name: string;
  description: string;
  occurredAt: string;
}

export function createPizza(
  attrs: CreatePizzaAttrs,
  repo: PizzaRepository
): CreatedPizza { ... }
```

### Repository (src/repositories/pizza_repository.ts)

```typescript
export class PizzaRepository {
  private store: Map<string, Pizza> = new Map();
  all(): Pizza[] { ... }
  find(id: string): Pizza | undefined { ... }
  save(entity: Pizza): void { ... }
  delete(id: string): void { ... }
}
```

### REST API (src/server.ts)

```
GET  /pizzas       — list all pizzas
GET  /pizzas/:id   — find pizza by ID
POST /pizzas/pizza — execute CreatePizza command
```

## Type Mapping

| Hecks DSL     | TypeScript                |
|---------------|---------------------------|
| String        | string                    |
| Integer       | number                    |
| Float         | number                    |
| Boolean       | boolean                   |
| Date/DateTime | string                    |
| JSON          | Record<string, unknown>   |
| list_of(X)    | X[]                       |
| reference_to  | string (stored as ID)     |

## Programmatic Use

```ruby
require "node_hecks"

domain = Hecks.domain("Pizzas") { ... }
path = NodeHecks::ProjectGenerator.new(domain, output_dir: ".").generate
# => "./pizzas_static_node"
```
