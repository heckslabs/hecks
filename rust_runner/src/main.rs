mod generated;
mod kernel;

use generated::order::{dispatch_create_pizza, dispatch_add_topping, CreatePizzaArgs, AddToppingArgs, Order, Pizza, PizzaName, Price, Size, ToppingName, ToppingAmount};
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

    // Now test AddTopping — an ACTING command with givens and mutations,
    // the main new feature this slice generates.

    println!("\n--- Testing AddTopping ---");

    let id = "Margherita";
    let topping_args = AddToppingArgs {
        topping: ToppingName { value: "Pepperoni".to_string() },
        amount: ToppingAmount { value: 1 },
    };

    match dispatch_add_topping(&mut repo, id, topping_args) {
        Ok((record, events)) => {
            println!("accepted: toppings now has {} items", record.toppings.len());
            for event in events {
                println!("emitted: {} for {} ({:?})", event.name, event.id, event.payload);
            }
        }
        Err(refusal) => println!("refused: {refusal}"),
    }

    // Add toppings until we hit the "at most 10 toppings" limit
    for i in 2..11 {
        let topping_args = AddToppingArgs {
            topping: ToppingName { value: format!("Topping{}", i) },
            amount: ToppingAmount { value: 1 },
        };
        match dispatch_add_topping(&mut repo, id, topping_args) {
            Ok((record, _)) => {
                println!("added topping {}: now has {} items", i, record.toppings.len());
            }
            Err(refusal) => {
                println!("topping {} refused: {refusal}", i);
                break;
            }
        }
    }

    // Try to add when already at the limit (should refuse with GivenNotMet)
    let topping_args = AddToppingArgs {
        topping: ToppingName { value: "ExtraTopping".to_string() },
        amount: ToppingAmount { value: 1 },
    };
    match dispatch_add_topping(&mut repo, id, topping_args) {
        Ok((record, _)) => println!("accepted (unexpected!): {record:?}"),
        Err(refusal) => println!("refused as expected: {refusal}"),
    }

    // Try to add to a pizza that was never created (should refuse with NotFound)
    let topping_args = AddToppingArgs {
        topping: ToppingName { value: "Mushroom".to_string() },
        amount: ToppingAmount { value: 1 },
    };
    match dispatch_add_topping(&mut repo, "NonExistentPizza", topping_args) {
        Ok((record, _)) => println!("accepted (unexpected!): {record:?}"),
        Err(refusal) => println!("refused as expected (not found): {refusal}"),
    }

    println!("\nrepository now holds {} record(s)", repo.count());
}
