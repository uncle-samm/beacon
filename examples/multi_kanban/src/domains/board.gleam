/// Board domain types — columns and cards for the kanban board.

pub type Column {
  Todo
  Doing
  Done
}

pub type Card {
  Card(id: Int, title: String, column: Column)
}
