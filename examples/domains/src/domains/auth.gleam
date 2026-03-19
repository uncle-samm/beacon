/// Auth domain — user types for the multi-file example.

pub type User {
  User(name: String, email: String, role: Role)
}

pub type Role {
  Admin
  Member
  Guest
}
