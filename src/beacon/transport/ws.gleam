/// WebSocket upgrade handshake and frame decoding.
/// Handles the HTTP→WebSocket upgrade (RFC 6455 Section 4) and
/// decodes client frames (which are always masked per Section 5.1).
///
/// Reference: RFC 6455 (The WebSocket Protocol).

import beacon/log
import beacon/transport/server
import gleam/bit_array
import gleam/http/request.{type Request}
import gleam/string

/// Decoded WebSocket frame types.
pub type WsFrame {
  /// Text frame (opcode 1) — UTF-8 text payload.
  TextFrame(String)
  /// Binary frame (opcode 2) — raw binary payload.
  BinaryFrame(BitArray)
  /// Close frame (opcode 8) — connection close request.
  CloseFrame
  /// Ping frame (opcode 9) — keepalive ping.
  PingFrame(BitArray)
  /// Pong frame (opcode 10) — keepalive response.
  PongFrame(BitArray)
}

/// FFI: compute Sec-WebSocket-Accept key.
@external(erlang, "beacon_transport_ffi", "ws_accept_key")
fn ffi_ws_accept_key(client_key: String) -> String

/// FFI: decode a WebSocket frame from raw bytes.
/// Returns: Ok(#(opcode, payload, remaining_data)) or Error("incomplete").
@external(erlang, "beacon_transport_ffi", "ws_decode_frame")
fn ffi_ws_decode_frame(
  data: BitArray,
) -> Result(#(Int, BitArray, BitArray), String)

/// Perform the WebSocket upgrade handshake.
/// Validates upgrade headers and sends the 101 Switching Protocols response.
pub fn upgrade(
  socket: server.Socket,
  req: Request(server.Connection),
) -> Result(Nil, String) {
  // Validate Upgrade header
  case request.get_header(req, "upgrade") {
    Error(Nil) -> Error("Missing Upgrade header")
    Ok(upgrade_val) -> {
      case string.lowercase(upgrade_val) == "websocket" {
        False -> Error("Invalid Upgrade header: " <> upgrade_val)
        True -> {
          // Validate Sec-WebSocket-Key
          case request.get_header(req, "sec-websocket-key") {
            Error(Nil) -> Error("Missing Sec-WebSocket-Key header")
            Ok(client_key) -> {
              let accept_key = ffi_ws_accept_key(client_key)
              let response_str =
                string.concat([
                  "HTTP/1.1 101 Switching Protocols\r\n",
                  "Upgrade: websocket\r\n",
                  "Connection: Upgrade\r\n",
                  "Sec-WebSocket-Accept: ",
                  accept_key,
                  "\r\n\r\n",
                ])
              let response_bytes = <<response_str:utf8>>
              case server.send_bytes(socket, response_bytes) {
                Ok(Nil) -> {
                  log.debug("beacon.ws", "WebSocket upgrade complete")
                  Ok(Nil)
                }
                Error(reason) -> Error("Failed to send upgrade: " <> reason)
              }
            }
          }
        }
      }
    }
  }
}

/// Decode a WebSocket frame from buffered data.
/// Returns Ok(#(frame, remaining_data)) on success,
/// Error("incomplete") if more data is needed.
pub fn decode_frame(
  data: BitArray,
) -> Result(#(WsFrame, BitArray), String) {
  case ffi_ws_decode_frame(data) {
    Ok(#(opcode, payload, rest)) -> {
      let frame = case opcode {
        // Text frame
        1 ->
          case bit_array.to_string(payload) {
            Ok(text) -> TextFrame(text)
            Error(Nil) -> {
              log.warning("beacon.ws", "Invalid UTF-8 in text frame")
              CloseFrame
            }
          }
        // Binary frame
        2 -> BinaryFrame(payload)
        // Close frame
        8 -> CloseFrame
        // Ping frame
        9 -> PingFrame(payload)
        // Pong frame
        10 -> PongFrame(payload)
        // Unknown opcode — treat as binary
        _ -> BinaryFrame(payload)
      }
      Ok(#(frame, rest))
    }
    Error(reason) -> Error(reason)
  }
}
