/// HTTP/1.1 request parsing and response writing.
/// Uses Erlang's inet:decode_packet(http_bin, ...) via FFI for efficient parsing.
///
/// Reference: RFC 7230 (HTTP/1.1 Message Syntax and Routing).

import beacon/transport/server
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Read an HTTP request from a socket.
/// Parses the request line and all headers using Erlang's http_bin packet mode.
@external(erlang, "beacon_transport_ffi", "read_http_request")
fn ffi_read_http_request(
  socket: server.Socket,
) -> Result(#(String, String, List(#(String, String))), String)

/// Read and parse an HTTP request from a socket into a gleam_http Request.
pub fn read_request(
  socket: server.Socket,
) -> Result(Request(server.Connection), String) {
  case ffi_read_http_request(socket) {
    Ok(#(method_str, raw_path, headers)) -> {
      let method = parse_method(method_str)
      let #(path, query) = split_path_query(raw_path)
      let host = find_header_value(headers, "host")
      let #(host_name, port_opt) = parse_host(host)
      Ok(request.Request(
        method: method,
        headers: headers,
        body: server.Connection,
        scheme: http.Http,
        host: host_name,
        port: port_opt,
        path: path,
        query: query,
      ))
    }
    Error(reason) -> Error(reason)
  }
}

/// Write an HTTP response to a socket.
/// Serializes status line, headers (with Content-Length), and body.
pub fn write_response(
  socket: server.Socket,
  resp: Response(server.ResponseBody),
) -> Result(Nil, String) {
  let body_bits = case resp.body {
    server.Bytes(tree) -> bytes_tree.to_bit_array(tree)
  }
  let body_size = bit_array.byte_size(body_bits)

  // Build response header string
  let status_line =
    "HTTP/1.1 "
    <> int.to_string(resp.status)
    <> " "
    <> reason_phrase(resp.status)
    <> "\r\n"
  let header_lines =
    list.map(resp.headers, fn(h) { h.0 <> ": " <> h.1 <> "\r\n" })
  let has_content_length =
    list.any(resp.headers, fn(h) { h.0 == "content-length" })
  let cl_line = case has_content_length {
    True -> ""
    False -> "content-length: " <> int.to_string(body_size) <> "\r\n"
  }
  let header_str =
    string.concat(
      list.flatten([[status_line], header_lines, [cl_line, "\r\n"]]),
    )
  let header_bits = <<header_str:utf8>>

  // Send headers + body in one write
  let full = bit_array.append(header_bits, body_bits)
  server.send_bytes(socket, full)
}

/// Write an error response and close the socket.
pub fn write_error(
  socket: server.Socket,
  status: Int,
  body: String,
) -> Nil {
  let resp =
    response.new(status)
    |> response.set_body(server.Bytes(bytes_tree.from_string(body)))
  let _ = write_response(socket, resp)
  server.close(socket)
}

// --- Internal helpers ---

fn parse_method(method_str: String) -> http.Method {
  case method_str {
    "GET" -> http.Get
    "POST" -> http.Post
    "PUT" -> http.Put
    "DELETE" -> http.Delete
    "HEAD" -> http.Head
    "OPTIONS" -> http.Options
    "PATCH" -> http.Patch
    _ -> http.Other(method_str)
  }
}

fn split_path_query(raw_path: String) -> #(String, Option(String)) {
  case string.split(raw_path, "?") {
    [path] -> #(path, None)
    [path, ..rest] -> #(path, Some(string.join(rest, "?")))
    _ -> #(raw_path, None)
  }
}

fn find_header_value(
  headers: List(#(String, String)),
  name: String,
) -> String {
  case headers {
    [] -> ""
    [#(key, value), ..rest] ->
      case key == name {
        True -> value
        False -> find_header_value(rest, name)
      }
  }
}

fn parse_host(host: String) -> #(String, Option(Int)) {
  case string.split(host, ":") {
    [name, port_str] ->
      case int.parse(port_str) {
        Ok(port) -> #(name, Some(port))
        Error(Nil) -> #(host, None)
      }
    _ -> #(host, None)
  }
}

fn reason_phrase(status: Int) -> String {
  case status {
    101 -> "Switching Protocols"
    200 -> "OK"
    204 -> "No Content"
    304 -> "Not Modified"
    400 -> "Bad Request"
    401 -> "Unauthorized"
    403 -> "Forbidden"
    404 -> "Not Found"
    413 -> "Payload Too Large"
    429 -> "Too Many Requests"
    500 -> "Internal Server Error"
    503 -> "Service Unavailable"
    _ -> "Unknown"
  }
}
