mod generated;
mod kernel;

use generated::order::{
    dispatch_add_topping, dispatch_create_pizza, dispatch_purchase, AddToppingArgs, CreatePizzaArgs,
    CustomerName, Order, Pizza, PizzaName, Price, PurchaseArgs, Size, ToppingAmount, ToppingName,
};
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

    // Purchase — a lifecycle transition (available -> sold), a literal
    // then_set mutation, and an argument-sourced one, all on one command.
    println!("\n--- Testing Purchase ---");

    let purchase_args = PurchaseArgs {
        customer_name: CustomerName { value: "Miette".to_string() },
        amount: Price { cents: 1500 },
    };
    match dispatch_purchase(&mut repo, id, purchase_args) {
        Ok((record, events)) => {
            println!("accepted: status is now {:?}", record.status);
            for event in events {
                println!("emitted: {} for {}", event.name, event.id);
            }
        }
        Err(refusal) => println!("refused: {refusal}"),
    }

    // The pizza is sold now — AddTopping's own "status == available" given
    // (generated two sections ago, unrelated to lifecycle at all) should
    // refuse it, proving the state genuinely advanced rather than main.rs
    // just trusting Purchase's own report of success.
    let post_sale_topping = AddToppingArgs {
        topping: ToppingName { value: "TooLate".to_string() },
        amount: ToppingAmount { value: 1 },
    };
    match dispatch_add_topping(&mut repo, id, post_sale_topping) {
        Ok((record, _)) => println!("accepted (unexpected!): {record:?}"),
        Err(refusal) => println!("refused as expected (sold): {refusal}"),
    }

    // And a second Purchase on the same, now-sold pizza should refuse via
    // admissible_transition — "sold" is not in Purchase's own from_states.
    let second_purchase = PurchaseArgs {
        customer_name: CustomerName { value: "Someone Else".to_string() },
        amount: Price { cents: 1500 },
    };
    match dispatch_purchase(&mut repo, id, second_purchase) {
        Ok((record, _)) => println!("accepted (unexpected!): {record:?}"),
        Err(refusal) => println!("refused as expected (already sold): {refusal}"),
    }

    println!("\nrepository now holds {} record(s)", repo.count());
}
