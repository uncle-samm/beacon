/// Beacon's minimal HTTP/WebSocket server built on gen_tcp.
/// Replaces Mist — provides only the functionality Beacon needs:
/// listen, accept, HTTP/1.1 request parsing, WebSocket upgrade + frames.
///
/// Reference: RFC 6455 (WebSocket), RFC 7230 (HTTP/1.1).

import beacon/log
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int

/// Connection type — phantom type used as the body parameter for gleam_http Request.
/// Beacon never reads HTTP request bodies, so this is a marker type.
pub type Connection {
  Connection
}

/// Response body type. Replaces mist.ResponseData.
pub type ResponseBody {
  /// Bytes response body wrapping a BytesTree.
  Bytes(BytesTree)
}

/// Opaque socket type wrapping an Erlang gen_tcp socket (port).
pub type Socket

/// TCP message classification — used to decode raw Erlang {tcp,...} messages.
pub type TcpMsg {
  /// TCP data received from the socket.
  TcpData(BitArray)
  /// TCP connection was closed by the peer.
  TcpClosed
  /// TCP error occurred.
  TcpError(String)
}

// --- TCP Operations (FFI wrappers) ---

/// Listen on a port with the given backlog size.
@external(erlang, "beacon_transport_ffi", "listen")
pub fn listen(port: Int, backlog: Int) -> Result(Socket, String)

/// Accept a connection on a listening socket (blocks until connection arrives).
@external(erlang, "beacon_transport_ffi", "accept")
pub fn accept(listen_socket: Socket) -> Result(Socket, String)

/// Send raw bytes over a socket.
@external(erlang, "beacon_transport_ffi", "tcp_send")
pub fn send_bytes(socket: Socket, data: BitArray) -> Result(Nil, String)

/// Close a socket.
@external(erlang, "beacon_transport_ffi", "close")
pub fn close(socket: Socket) -> Nil

/// Transfer socket ownership to another process.
@external(erlang, "beacon_transport_ffi", "controlling_process")
pub fn controlling_process(
  socket: Socket,
  pid: process.Pid,
) -> Result(Nil, String)

/// Set socket to {active, once} mode — delivers one {tcp,...} message.
@external(erlang, "beacon_transport_ffi", "set_active_once")
pub fn set_active_once(socket: Socket) -> Nil

// --- WebSocket Operations ---

/// Encode text as a WebSocket text frame (server→client, unmasked).
@external(erlang, "beacon_transport_ffi", "ws_encode_text_frame")
fn ffi_ws_encode_text_frame(text: String) -> BitArray

/// Encode a WebSocket close frame.
@external(erlang, "beacon_transport_ffi", "ws_encode_close_frame")
fn ffi_ws_encode_close_frame() -> BitArray

/// Send a WebSocket text frame.
pub fn send_text_frame(socket: Socket, text: String) -> Result(Nil, String) {
  let frame = ffi_ws_encode_text_frame(text)
  send_bytes(socket, frame)
}

/// Send a WebSocket close frame.
pub fn send_close_frame(socket: Socket) -> Result(Nil, String) {
  let frame = ffi_ws_encode_close_frame()
  send_bytes(socket, frame)
}

// --- TCP Message Classification ---

/// Classify a raw Erlang message into a TcpMsg.
/// Used with process.selecting_anything to decode {tcp,...} messages.
@external(erlang, "beacon_transport_ffi", "classify_tcp_message")
pub fn classify_tcp_message(raw: Dynamic) -> Result(TcpMsg, Nil)

// --- Acceptor Loop (FFI) ---

/// Start N acceptors and wait for all to signal readiness.
/// Ensures all acceptors are blocked on gen_tcp:accept before returning.
@external(erlang, "beacon_transport_ffi", "start_acceptor_pool")
fn ffi_start_acceptor_pool(
  listen_socket: Socket,
  handler: fn(Socket) -> Nil,
  count: Int,
) -> Nil

// --- Server Start ---

/// Start the server: listen on port, spawn acceptor pool.
/// Returns the server process Pid (which owns the listen socket).
pub fn start(
  port: Int,
  handler: fn(Socket) -> Nil,
  acceptor_count: Int,
) -> Result(process.Pid, String) {
  case listen(port, 128) {
    Ok(listen_socket) -> {
      let caller = process.new_subject()
      let server_pid =
        process.spawn(fn() {
          // Start acceptors and wait for ALL to be ready before signaling.
          // Ensures acceptors are blocked on accept before connections arrive.
          ffi_start_acceptor_pool(listen_socket, handler, acceptor_count)
          process.send(caller, Ok(Nil))
          // Keep alive — owns the listen socket
          process.sleep_forever()
        })
      case process.receive(caller, 5000) {
        Ok(Ok(Nil)) -> {
          log.info(
            "beacon.server",
            "Listening on port "
              <> int.to_string(port)
              <> " with "
              <> int.to_string(acceptor_count)
              <> " acceptors",
          )
          Ok(server_pid)
        }
        Ok(Error(reason)) -> Error(reason)
        Error(Nil) -> Error("Server start timeout")
      }
    }
    Error(reason) -> Error(reason)
  }
}
