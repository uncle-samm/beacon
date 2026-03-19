/// Task domain — represents a single to-do item.

pub type TodoItem {
  TodoItem(id: Int, text: String, completed: Bool)
}

pub type Filter {
  All
  Active
  Completed
}
