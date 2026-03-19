/// Shopping Cart — demonstrates:
/// - Computed/derived values in view (subtotal, tax, total NOT in model)
/// - Multiple model fields change from one action (products + cart_items)
/// - Multi-user shared product stock via store
/// - Patch patterns: two arrays change per action

import beacon
import beacon/effect
import beacon/html
import beacon/pubsub
import beacon/store
import gleam/float
import gleam/int
import gleam/list
import gleam/string

// --- Types ---

pub type Product {
  Product(id: Int, name: String, price: Int, stock: Int)
}

pub type CartItem {
  CartItem(product_id: Int, name: String, price: Int, quantity: Int)
}

pub type Model {
  Model(
    products: List(Product),
    cart_items: List(CartItem),
  )
}

pub type Local {
  Local
}

pub type Msg {
  AddToCart(String)
  RemoveFromCart(String)
  IncrementQty(String)
  DecrementQty(String)
  StockUpdated
  SetProducts(List(Product))
}

fn default_products() -> List(Product) {
  [
    Product(id: 1, name: "Laptop", price: 999, stock: 5),
    Product(id: 2, name: "Mouse", price: 29, stock: 20),
    Product(id: 3, name: "Keyboard", price: 79, stock: 15),
    Product(id: 4, name: "Monitor", price: 449, stock: 8),
    Product(id: 5, name: "Headphones", price: 149, stock: 12),
  ]
}

// --- Init ---

pub fn init() -> Model {
  Model(products: default_products(), cart_items: [])
}

pub fn init_local(_model: Model) -> Local {
  Local
}

// --- Update (pure — compiles to JS) ---

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    AddToCart(id_str) -> {
      case int.parse(id_str) {
        Ok(id) -> {
          case list.find(model.products, fn(p) { p.id == id && p.stock > 0 }) {
            Ok(product) -> {
              let new_products =
                list.map(model.products, fn(p) {
                  case p.id == id {
                    True -> Product(..p, stock: p.stock - 1)
                    False -> p
                  }
                })
              let new_cart = case list.find(model.cart_items, fn(c) { c.product_id == id }) {
                Ok(_) ->
                  list.map(model.cart_items, fn(c) {
                    case c.product_id == id {
                      True -> CartItem(..c, quantity: c.quantity + 1)
                      False -> c
                    }
                  })
                Error(_) ->
                  list.append(model.cart_items, [
                    CartItem(
                      product_id: product.id,
                      name: product.name,
                      price: product.price,
                      quantity: 1,
                    ),
                  ])
              }
              #(Model(products: new_products, cart_items: new_cart), local)
            }
            Error(_) -> #(model, local)
          }
        }
        Error(_) -> #(model, local)
      }
    }

    RemoveFromCart(id_str) -> {
      case int.parse(id_str) {
        Ok(id) -> {
          case list.find(model.cart_items, fn(c) { c.product_id == id }) {
            Ok(item) -> {
              let new_products =
                list.map(model.products, fn(p) {
                  case p.id == id {
                    True -> Product(..p, stock: p.stock + item.quantity)
                    False -> p
                  }
                })
              let new_cart =
                list.filter(model.cart_items, fn(c) { c.product_id != id })
              #(Model(products: new_products, cart_items: new_cart), local)
            }
            Error(_) -> #(model, local)
          }
        }
        Error(_) -> #(model, local)
      }
    }

    IncrementQty(id_str) -> {
      case int.parse(id_str) {
        Ok(id) -> {
          case list.find(model.products, fn(p) { p.id == id && p.stock > 0 }) {
            Ok(_) -> {
              let new_products =
                list.map(model.products, fn(p) {
                  case p.id == id {
                    True -> Product(..p, stock: p.stock - 1)
                    False -> p
                  }
                })
              let new_cart =
                list.map(model.cart_items, fn(c) {
                  case c.product_id == id {
                    True -> CartItem(..c, quantity: c.quantity + 1)
                    False -> c
                  }
                })
              #(Model(products: new_products, cart_items: new_cart), local)
            }
            Error(_) -> #(model, local)
          }
        }
        Error(_) -> #(model, local)
      }
    }

    DecrementQty(id_str) -> {
      case int.parse(id_str) {
        Ok(id) -> {
          case list.find(model.cart_items, fn(c) { c.product_id == id && c.quantity > 1 }) {
            Ok(_) -> {
              let new_products =
                list.map(model.products, fn(p) {
                  case p.id == id {
                    True -> Product(..p, stock: p.stock + 1)
                    False -> p
                  }
                })
              let new_cart =
                list.map(model.cart_items, fn(c) {
                  case c.product_id == id {
                    True -> CartItem(..c, quantity: c.quantity - 1)
                    False -> c
                  }
                })
              #(Model(products: new_products, cart_items: new_cart), local)
            }
            Error(_) -> {
              // Quantity is 1, remove instead
              update(model, local, RemoveFromCart(id_str))
            }
          }
        }
        Error(_) -> #(model, local)
      }
    }

    StockUpdated -> #(model, local)

    SetProducts(products) -> #(Model(..model, products: products), local)
  }
}

// --- Side Effects ---

fn make_on_update(
  product_store: store.ListStore(Product),
) -> fn(#(Model, Local), Msg) -> effect.Effect(Msg) {
  fn(state: #(Model, Local), msg: Msg) -> effect.Effect(Msg) {
    let #(model, _local) = state
    case msg {
      AddToCart(_) | RemoveFromCart(_) | IncrementQty(_) | DecrementQty(_) ->
        effect.from(fn(_dispatch) {
          store.delete_all(product_store, "products")
          store.append_many(product_store, "products", model.products)
          pubsub.broadcast("cart:stock", Nil)
        })
      StockUpdated -> {
        let store_products = store.get_all(product_store, "products")
        case list.length(store_products) > 0 {
          True ->
            effect.from(fn(dispatch) { dispatch(SetProducts(store_products)) })
          False -> effect.none()
        }
      }
      _ -> effect.none()
    }
  }
}

// --- View ---

pub fn view(model: Model, _local: Local) -> beacon.Node(Msg) {
  // Computed values — derived in view, NOT stored in model
  let subtotal =
    list.fold(model.cart_items, 0, fn(sum, item) {
      sum + item.price * item.quantity
    })
  let tax = subtotal / 10
  let total = subtotal + tax

  html.div(
    [html.style("font-family:system-ui;max-width:800px;margin:2rem auto;padding:0 1rem")],
    [
      html.h1([], [html.text("Shopping Cart")]),
      html.div(
        [html.style("display:grid;grid-template-columns:1fr 1fr;gap:2rem")],
        [
          // Products
          html.div([], [
            html.h2([], [html.text("Products")]),
            html.div([], list.map(model.products, render_product)),
          ]),
          // Cart
          html.div([], [
            html.h2([], [html.text("Cart")]),
            case model.cart_items {
              [] ->
                html.p([html.style("color:#999")], [
                  html.text("Cart is empty"),
                ])
              items ->
                html.div([], [
                  html.div([], list.map(items, render_cart_item)),
                  // Totals
                  html.div(
                    [html.style("border-top:2px solid #333;margin-top:1rem;padding-top:1rem")],
                    [
                      total_row("Subtotal", subtotal),
                      total_row("Tax (10%)", tax),
                      html.div(
                        [html.style("display:flex;justify-content:space-between;font-weight:bold;font-size:18px;margin-top:8px")],
                        [
                          html.span([], [html.text("Total")]),
                          html.span([], [
                            html.text("$" <> int.to_string(total)),
                          ]),
                        ],
                      ),
                    ],
                  ),
                ])
            },
          ]),
        ],
      ),
    ],
  )
}

fn render_product(product: Product) -> beacon.Node(Msg) {
  html.div(
    [html.style("display:flex;justify-content:space-between;align-items:center;padding:12px;border:1px solid #eee;border-radius:8px;margin-bottom:8px")],
    [
      html.div([], [
        html.div([html.style("font-weight:500")], [html.text(product.name)]),
        html.div([html.style("color:#666;font-size:14px")], [
          html.text(
            "$" <> int.to_string(product.price) <> " | Stock: " <> int.to_string(product.stock),
          ),
        ]),
      ]),
      case product.stock > 0 {
        True ->
          html.button(
            [
              beacon.on_click(AddToCart(int.to_string(product.id))),
              html.style("padding:8px 16px;background:#4CAF50;color:white;border:none;border-radius:6px;cursor:pointer"),
            ],
            [html.text("Add")],
          )
        False ->
          html.span([html.style("color:#999;font-size:14px")], [
            html.text("Out of stock"),
          ])
      },
    ],
  )
}

fn render_cart_item(item: CartItem) -> beacon.Node(Msg) {
  let line_total = item.price * item.quantity
  let id_str = int.to_string(item.product_id)
  html.div(
    [html.style("display:flex;justify-content:space-between;align-items:center;padding:8px 0;border-bottom:1px solid #f0f0f0")],
    [
      html.div([], [
        html.span([html.style("font-weight:500")], [html.text(item.name)]),
        html.span([html.style("color:#666;margin-left:8px;font-size:14px")], [
          html.text("$" <> int.to_string(item.price) <> " each"),
        ]),
      ]),
      html.div([html.style("display:flex;align-items:center;gap:8px")], [
        html.button(
          [
            beacon.on_click(DecrementQty(id_str)),
            html.style("width:28px;height:28px;border:1px solid #ddd;border-radius:4px;cursor:pointer;background:white"),
          ],
          [html.text("-")],
        ),
        html.span([html.style("min-width:20px;text-align:center")], [
          html.text(int.to_string(item.quantity)),
        ]),
        html.button(
          [
            beacon.on_click(IncrementQty(id_str)),
            html.style("width:28px;height:28px;border:1px solid #ddd;border-radius:4px;cursor:pointer;background:white"),
          ],
          [html.text("+")],
        ),
        html.span([html.style("min-width:60px;text-align:right;font-weight:500")], [
          html.text("$" <> int.to_string(line_total)),
        ]),
        html.button(
          [
            beacon.on_click(RemoveFromCart(id_str)),
            html.style("background:none;border:none;color:#e57373;cursor:pointer;font-size:16px"),
          ],
          [html.text("x")],
        ),
      ]),
    ],
  )
}

fn total_row(label: String, amount: Int) -> beacon.Node(Msg) {
  html.div(
    [html.style("display:flex;justify-content:space-between;color:#666;font-size:14px;margin-bottom:4px")],
    [
      html.span([], [html.text(label)]),
      html.span([], [html.text("$" <> int.to_string(amount))]),
    ],
  )
}

// --- Start ---

pub fn main() {
  start()
}

pub fn start() {
  let product_store = store.new_list("cart_products")

  // Seed store with initial products if empty
  case store.get_all(product_store, "products") {
    [] -> store.append_many(product_store, "products", default_products())
    _ -> Nil
  }

  let init_from_store = fn() {
    let products = case store.get_all(product_store, "products") {
      [] -> default_products()
      stored -> stored
    }
    Model(products: products, cart_items: [])
  }

  beacon.app_with_local(init_from_store, init_local, update, view)
  |> beacon.title("Shopping Cart")
  |> beacon.on_update(make_on_update(product_store))
  |> beacon.subscriptions(fn(_model) { ["cart:stock"] })
  |> beacon.on_notify(fn(_topic) { StockUpdated })
  |> beacon.start(8080)
}
