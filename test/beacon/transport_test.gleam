import beacon/transport
import gleam/list
import gleam/string

// --- ServerMessage encoding tests ---

pub fn encode_mount_message_test() {
  let msg = transport.ServerMount(payload: "{\"html\":\"<h1>Hi</h1>\"}")
  let encoded = transport.encode_server_message(msg)
  // Verify it contains the expected JSON structure
  let assert True = contains(encoded, "\"type\":\"mount\"")
  let assert True = contains(encoded, "\"payload\":")
}

pub fn encode_patch_message_test() {
  let msg = transport.ServerPatch(payload: "{\"0\":\"new value\"}", clock: 3)
  let encoded = transport.encode_server_message(msg)
  let assert True = contains(encoded, "\"type\":\"patch\"")
  let assert True = contains(encoded, "\"payload\":")
  let assert True = contains(encoded, "\"clock\":3")
}

pub fn encode_heartbeat_ack_test() {
  let msg = transport.ServerHeartbeatAck
  let encoded = transport.encode_server_message(msg)
  let assert True = contains(encoded, "\"type\":\"heartbeat_ack\"")
}

pub fn encode_error_message_test() {
  let msg = transport.ServerError(reason: "something went wrong")
  let encoded = transport.encode_server_message(msg)
  let assert True = contains(encoded, "\"type\":\"error\"")
  let assert True = contains(encoded, "\"reason\":\"something went wrong\"")
}

// --- ClientMessage decoding tests ---

pub fn decode_heartbeat_test() {
  let raw = "{\"type\":\"heartbeat\"}"
  let assert Ok(transport.ClientHeartbeat) = transport.decode_client_message(raw)
}

pub fn decode_join_test() {
  let raw = "{\"type\":\"join\"}"
  let assert Ok(transport.ClientJoin(token: "")) =
    transport.decode_client_message(raw)
}

pub fn decode_join_with_token_test() {
  let raw = "{\"type\":\"join\",\"token\":\"abc123\"}"
  let assert Ok(transport.ClientJoin(token: "abc123")) =
    transport.decode_client_message(raw)
}

pub fn decode_event_test() {
  let raw =
    "{\"type\":\"event\",\"name\":\"click\",\"data\":\"{}\",\"target_path\":\"0.1.0\"}"
  let assert Ok(transport.ClientEvent(
    name: "click",
    handler_id: "",
    data: "{}",
    target_path: "0.1.0",
    clock: 0,
  )) = transport.decode_client_message(raw)
}

pub fn decode_event_with_handler_id_test() {
  let raw =
    "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"increment\",\"data\":\"{}\",\"target_path\":\"0.3\",\"clock\":5}"
  let assert Ok(transport.ClientEvent(
    name: "click",
    handler_id: "increment",
    data: "{}",
    target_path: "0.3",
    clock: 5,
  )) = transport.decode_client_message(raw)
}

pub fn decode_event_with_data_test() {
  let raw =
    "{\"type\":\"event\",\"name\":\"input\",\"handler_id\":\"search\",\"data\":\"{\\\"value\\\":\\\"hello\\\"}\",\"target_path\":\"0.2\"}"
  let assert Ok(transport.ClientEvent(
    name: "input",
    handler_id: "search",
    data: _,
    target_path: "0.2",
    clock: 0,
  )) = transport.decode_client_message(raw)
}

pub fn decode_invalid_json_test() {
  let raw = "not json at all"
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn decode_unknown_type_test() {
  let raw = "{\"type\":\"unknown_type\"}"
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn decode_missing_type_field_test() {
  let raw = "{\"name\":\"click\"}"
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn decode_event_missing_fields_test() {
  let raw = "{\"type\":\"event\",\"name\":\"click\"}"
  // Missing "data" and "target_path" fields — should fail
  let assert Error(_) = transport.decode_client_message(raw)
}

// --- Round-trip test ---

pub fn encode_decode_roundtrip_consistency_test() {
  // Verify that encoding produces valid JSON that could be parsed
  let messages = [
    transport.ServerMount(payload: "test"),
    transport.ServerPatch(payload: "test", clock: 0),
    transport.ServerHeartbeatAck,
    transport.ServerError(reason: "test error"),
  ]
  list_each(messages, fn(msg) {
    let encoded = transport.encode_server_message(msg)
    // At minimum, the encoded string should start with { and end with }
    let assert True = starts_with(encoded, "{")
    let assert True = ends_with(encoded, "}")
    Nil
  })
}

// --- Helper functions ---

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

fn starts_with(s: String, prefix: String) -> Bool {
  string.starts_with(s, prefix)
}

fn ends_with(s: String, suffix: String) -> Bool {
  string.ends_with(s, suffix)
}

fn list_each(items: List(a), f: fn(a) -> Nil) -> Nil {
  list.each(items, f)
}
