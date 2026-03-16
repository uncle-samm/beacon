/// Cookie-based session management.
/// Sessions are stored in ETS (server-side) with a session ID in a cookie.

import beacon/log
import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}

/// A session with key-value data.
pub type Session {
  Session(
    /// Unique session identifier (stored in cookie).
    id: String,
    /// Session data (key-value pairs).
    data: Dict(String, String),
  )
}

/// Session store backed by ETS.
pub type SessionStore {
  SessionStore(table: SessionTable)
}

/// Opaque ETS table reference.
pub type SessionTable

/// Create a new session store.
pub fn new_store(name: String) -> SessionStore {
  SessionStore(table: session_ets_new(name))
}

/// Create a new session with a generated ID.
pub fn create(store: SessionStore) -> Session {
  let id = generate_session_id()
  let session = Session(id: id, data: dict.new())
  session_ets_put(store.table, id, session)
  log.debug("beacon.session", "Created session: " <> id)
  session
}

/// Get a session by ID.
pub fn get(store: SessionStore, id: String) -> Option(Session) {
  case session_ets_get(store.table, id) {
    Ok(session) -> Some(session)
    Error(Nil) -> None
  }
}

/// Set a value in a session.
pub fn set(
  store: SessionStore,
  session: Session,
  key: String,
  value: String,
) -> Session {
  let new_data = dict.insert(session.data, key, value)
  let updated = Session(..session, data: new_data)
  session_ets_put(store.table, session.id, updated)
  updated
}

/// Get a value from a session.
pub fn get_value(session: Session, key: String) -> Option(String) {
  case dict.get(session.data, key) {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

/// Delete a session (logout).
pub fn delete(store: SessionStore, id: String) -> Nil {
  session_ets_delete(store.table, id)
  log.debug("beacon.session", "Deleted session: " <> id)
}

// === FFI ===

@external(erlang, "beacon_session_ffi", "session_ets_new")
fn session_ets_new(name: String) -> SessionTable

@external(erlang, "beacon_session_ffi", "session_ets_put")
fn session_ets_put(table: SessionTable, key: String, value: Session) -> Nil

@external(erlang, "beacon_session_ffi", "session_ets_get")
fn session_ets_get(
  table: SessionTable,
  key: String,
) -> Result(Session, Nil)

@external(erlang, "beacon_session_ffi", "session_ets_delete")
fn session_ets_delete(table: SessionTable, key: String) -> Nil

@external(erlang, "beacon_session_ffi", "generate_session_id")
fn generate_session_id() -> String
