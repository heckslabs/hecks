mod generated;
mod kernel;

use generated::order::{dispatch_create_pizza, CreatePizzaArgs, Order, Pizza, PizzaName, Price, Size};
use kernel::{InMemoryRepository, Repository};

fn main() {
    let mut repo: InMemoryRepository<Order> = InMemoryRepository::new();

    let args = CreatePizzaArgs {
        name: PizzaName { value: "Margherita".to_string() },
        pizza: Pizza { price_cents: Price { cents: 1200 }, size: Size::Large },
    };

    match dispatch_create_pizza(&mut repo, args) {
        Ok((record, events)) => {
            println!("accepted: {record:?}");
            for event in events {
                println!("emitted: {} for {} ({:?})", event.name, event.id, event.payload);
            }
        }
        Err(refusal) => println!("refused: {refusal}"),
    }

    let dup_args = CreatePizzaArgs {
        name: PizzaName { value: "Margherita".to_string() },
        pizza: Pizza { price_cents: Price { cents: 900 }, size: Size::Small },
    };

    match dispatch_create_pizza(&mut repo, dup_args) {
        Ok((record, _)) => println!("accepted (unexpected!): {record:?}"),
        Err(refusal) => println!("refused: {refusal}"),
    }

    // Now a REAL refusal, not a known gap: PizzaName's own invariant ("a
    // pizza is named") is generated and checked before identity is even
    // derived, exactly where docs/guides/writing-a-port.md's dispatch-order
    // section places it (`normalize_args`, ahead of `hydrate`).
    let empty_name_args = CreatePizzaArgs {
        name: PizzaName { value: "".to_string() },
        pizza: Pizza { price_cents: Price { cents: 500 }, size: Size::Small },
    };

    match dispatch_create_pizza(&mut repo, empty_name_args) {
        Ok((record, _)) => println!("accepted (unexpected!): {record:?}"),
        Err(refusal) => println!("refused: {refusal}"),
    }

    // And the invariant this slice still does NOT generate a check for:
    // `given`/`ensures` on ACTING commands. AddTopping is out of scope
    // (it declares `references` and `mutations`), so nothing here even
    // attempts it — the gap is in what bin/project_rust skips generating,
    // not in what the generated code silently accepts.

    println!("repository now holds {} record(s)", repo.count());
}
