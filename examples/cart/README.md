# Shopping Cart

Product catalog with add-to-cart, quantity controls, and computed totals.

## Features

- Computed/derived values in view (subtotal, tax, total -- not stored in model)
- Add, remove, increment, decrement cart items with stock tracking
- Multi-user shared product stock via store and PubSub
- Two-column layout: product list and cart summary

## Run

```bash
cd examples/cart
gleam run
```

Open http://localhost:8080 -- add products to your cart and see live subtotal/tax/total.
