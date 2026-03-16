import beacon/auth
import beacon/session
import gleam/option.{Some}

pub fn login_creates_session_test() {
  let store = session.new_store("auth_login")
  let sess = auth.login(store, "user123")
  // Session should exist with user_id
  let assert Some(found) = session.get(store, sess.id)
  let assert Ok("user123") = auth.current_user(found)
}

pub fn logout_destroys_session_test() {
  let store = session.new_store("auth_logout")
  let sess = auth.login(store, "user456")
  auth.logout(store, sess.id)
  // Session should be gone
  let assert option.None = session.get(store, sess.id)
}

pub fn current_user_no_user_test() {
  let store = session.new_store("auth_nouser")
  let sess = session.create(store)
  // No user_id set
  let assert Error(Nil) = auth.current_user(sess)
}

pub fn current_user_with_user_test() {
  let store = session.new_store("auth_withuser")
  let sess = auth.login(store, "admin")
  let assert Ok("admin") = auth.current_user(sess)
}
