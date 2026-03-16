/// Beacon's WebSocket transport layer.
/// Manages WebSocket connections using Mist, with one BEAM process per connection.
/// Follows LiveView's connection lifecycle: connect → init → handle messages → close.
///
/// Reference: Mist v5.0.4 WebSocket API, LiveView channel protocol.

import beacon/error
import beacon/log
import beacon/middleware
import beacon/pubsub
import beacon/static
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import mist

/// Unique identifier for a WebSocket connection.
/// Used for logging and session tracking.
pub type ConnectionId =
  String

/// Messages sent from the client (browser) to the server.
/// This is Beacon's wire protocol — not Lustre's internal format.
pub type ClientMessage {
  /// A DOM event was fired (click, input, submit, etc).
  ClientEvent(
    /// The event name (e.g. "click", "input").
    name: String,
    /// The handler identifier from the data-beacon-event-* attribute value.
    /// This is the semantic identifier set by the view (e.g. "increment", "decrement").
    handler_id: String,
    /// JSON-encoded event data.
    data: String,
    /// Path to the element in the VDOM tree that fired the event.
    target_path: String,
    /// Monotonic event clock value for ordering and acknowledgment.
    /// Reference: LiveView 1.1 event clocking.
    clock: Int,
  )
  /// Client sends a heartbeat to keep the connection alive.
  ClientHeartbeat
  /// Client is requesting initial state after connecting.
  /// Includes an optional session token for state recovery.
  ClientJoin(token: String)
}

/// Messages sent from the server to the client (browser).
pub type ServerMessage {
  /// Initial mount: full rendered content sent on first connect.
  ServerMount(payload: String)
  /// Incremental update: only the changed parts (patches).
  /// Includes the clock value of the event that triggered this update,
  /// so the client can acknowledge and unlock DOM regions.
  ServerPatch(payload: String, clock: Int)
  /// Server acknowledges a heartbeat.
  ServerHeartbeatAck
  /// Server-initiated error message.
  ServerError(reason: String)
  /// Authoritative Model state from server.
  /// Client takes this as ground truth, keeps its Local state.
  ServerModelSync(model_json: String, version: Int, ack_clock: Int)
}

/// Internal messages that the connection actor can receive.
/// These come either from the WebSocket (client) or from
/// other BEAM processes (e.g. the runtime pushing patches).
pub type InternalMessage {
  /// A patch needs to be sent to the client.
  /// Includes the event clock value for client acknowledgment.
  SendPatch(payload: String, clock: Int)
  /// A mount payload needs to be sent to the client.
  SendMount(payload: String)
  /// An error needs to be sent to the client.
  SendError(reason: String)
  /// Send authoritative Model state to the client.
  SendModelSync(model_json: String, version: Int, ack_clock: Int)
}

/// State held by each WebSocket connection actor.
pub type ConnectionState {
  ConnectionState(
    /// Unique ID for this connection, used in logging.
    id: ConnectionId,
    /// The WebSocket connection handle for sending frames.
    connection: mist.WebsocketConnection,
    /// Callback invoked when a client event is received (per-connection).
    on_event: fn(ConnectionId, ClientMessage) -> Nil,
    /// Callback invoked when this connection closes (per-connection).
    on_close: fn(ConnectionId) -> Nil,
  )
}

/// Configuration for the transport layer.
pub type TransportConfig {
  TransportConfig(
    /// Port to listen on.
    port: Int,
    /// Callback invoked when a new WebSocket connection is established.
    on_connect: fn(ConnectionId, process.Subject(InternalMessage)) -> Nil,
    /// Callback invoked when a client sends an event.
    on_event: fn(ConnectionId, ClientMessage) -> Nil,
    /// Callback invoked when a WebSocket connection closes.
    on_disconnect: fn(ConnectionId) -> Nil,
    /// Optional: pre-rendered HTML page for SSR.
    /// If provided, HTTP requests get this instead of the default page.
    page_html: Option(String),
    /// Optional: middleware pipeline applied to all HTTP requests.
    /// Middleware runs before routing (SSR, static files, WebSocket upgrade).
    middlewares: List(middleware.Middleware),
    /// Optional: static file serving configuration.
    static_config: Option(static.StaticConfig),
    /// Optional: factory that creates a per-connection runtime.
    /// If set, each WebSocket connection gets its OWN runtime (like LiveView).
    /// The factory returns callbacks for this specific connection's runtime.
    /// If None, uses the shared on_connect/on_event/on_disconnect callbacks.
    runtime_factory: Option(
      fn(ConnectionId, process.Subject(InternalMessage)) ->
        #(
          fn(ConnectionId, ClientMessage) -> Nil,
          fn(ConnectionId) -> Nil,
        ),
    ),
  )
}

/// Generate a unique connection ID.
/// Uses a combination of the current monotonic time and a unique integer.
fn generate_connection_id() -> ConnectionId {
  let time = erlang_monotonic_time()
  let unique = erlang_unique_integer()
  "conn_" <> int.to_string(time) <> "_" <> int.to_string(unique)
}

@external(erlang, "erlang", "monotonic_time")
fn erlang_monotonic_time() -> Int

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

/// Encode a ServerMessage to JSON string for sending over the wire.
pub fn encode_server_message(msg: ServerMessage) -> String {
  case msg {
    ServerMount(payload) ->
      json.object([
        #("type", json.string("mount")),
        #("payload", json.string(payload)),
      ])
      |> json.to_string
    ServerPatch(payload, clock) ->
      json.object([
        #("type", json.string("patch")),
        #("payload", json.string(payload)),
        #("clock", json.int(clock)),
      ])
      |> json.to_string
    ServerHeartbeatAck ->
      json.object([#("type", json.string("heartbeat_ack"))])
      |> json.to_string
    ServerError(reason) ->
      json.object([
        #("type", json.string("error")),
        #("reason", json.string(reason)),
      ])
      |> json.to_string
    ServerModelSync(model_json, version, ack_clock) ->
      json.object([
        #("type", json.string("model_sync")),
        #("model", json.string(model_json)),
        #("version", json.int(version)),
        #("ack_clock", json.int(ack_clock)),
      ])
      |> json.to_string
  }
}

/// Build a decoder for ClientMessage JSON.
/// Uses the "type" field to determine which variant to decode.
/// Follows Lustre's transport.server_message_decoder() pattern.
fn client_message_decoder() -> decode.Decoder(ClientMessage) {
  use msg_type <- decode.field("type", decode.string)
  case msg_type {
    "event" -> {
      use name <- decode.field("name", decode.string)
      use handler_id <- decode.optional_field("handler_id", "", decode.string)
      use data <- decode.field("data", decode.string)
      use target_path <- decode.field("target_path", decode.string)
      use clock <- decode.optional_field("clock", 0, decode.int)
      decode.success(ClientEvent(
        name: name,
        handler_id: handler_id,
        data: data,
        target_path: target_path,
        clock: clock,
      ))
    }
    "heartbeat" -> decode.success(ClientHeartbeat)
    "join" -> {
      use token <- decode.optional_field("token", "", decode.string)
      decode.success(ClientJoin(token: token))
    }
    _unknown -> decode.failure(ClientHeartbeat, "ClientMessage type")
  }
}

/// Decode a JSON string from the client into a ClientMessage.
pub fn decode_client_message(
  raw: String,
) -> Result(ClientMessage, error.BeaconError) {
  case json.parse(raw, client_message_decoder()) {
    Ok(msg) -> {
      log.debug("beacon.transport", "Decoded client message")
      Ok(msg)
    }
    Error(_json_err) -> {
      log.warning("beacon.transport", "Failed to decode client message")
      Error(error.CodecError(
        reason: "Failed to decode client message",
        raw: raw,
      ))
    }
  }
}

/// Send a ServerMessage over a WebSocket connection.
/// Logs errors but does not crash — the connection may have closed.
fn send_message(
  conn: mist.WebsocketConnection,
  conn_id: ConnectionId,
  msg: ServerMessage,
) -> Nil {
  let encoded = encode_server_message(msg)
  case mist.send_text_frame(conn, encoded) {
    Ok(Nil) -> {
      log.debug("beacon.transport", "Sent message to " <> conn_id)
      Nil
    }
    Error(_reason) -> {
      log.error(
        "beacon.transport",
        "Failed to send message to "
          <> conn_id
          <> ": send_text_frame failed",
      )
      Nil
    }
  }
}

/// Handle an incoming WebSocket text frame.
/// Decodes the message and dispatches to the appropriate handler.
fn handle_text_message(
  state: ConnectionState,
  text: String,
) -> mist.Next(ConnectionState, InternalMessage) {
  case decode_client_message(text) {
    Ok(ClientHeartbeat) -> {
      log.debug("beacon.transport", "Heartbeat from " <> state.id)
      send_message(state.connection, state.id, ServerHeartbeatAck)
      mist.continue(state)
    }
    Ok(msg) -> {
      log.debug(
        "beacon.transport",
        "Event from " <> state.id <> ": " <> string.inspect(msg),
      )
      state.on_event(state.id, msg)
      mist.continue(state)
    }
    Error(err) -> {
      let err_str = error.to_string(err)
      log.warning(
        "beacon.transport",
        "Decode error from " <> state.id <> ": " <> err_str,
      )
      send_message(
        state.connection,
        state.id,
        ServerError(reason: "Invalid message: " <> err_str),
      )
      mist.continue(state)
    }
  }
}

/// Create the HTTP handler that upgrades WebSocket connections
/// and serves a basic HTML page for non-WebSocket requests.
/// Applies middleware pipeline to all HTTP requests.
/// Checks static file serving before app routes.
pub fn create_handler(
  config: TransportConfig,
) -> fn(Request(mist.Connection)) -> response.Response(mist.ResponseData) {
  // The core handler (before middleware)
  let core_handler = fn(req: Request(mist.Connection)) {
    case request.path_segments(req) {
      ["ws"] -> handle_websocket(req, config)
      ["beacon.js"] -> serve_js()
      _ -> {
        // Try static files first
        case config.static_config {
          Some(static_cfg) -> {
            let if_none_match =
              case request.get_header(req, "if-none-match") {
                Ok(val) -> val
                Error(Nil) -> ""
              }
            case
              static.serve_with_etag_check(
                static_cfg,
                req.path,
                if_none_match,
              )
            {
              Ok(resp) -> resp
              Error(Nil) -> serve_page(config.page_html)
            }
          }
          None -> serve_page(config.page_html)
        }
      }
    }
  }
  // Wrap with middleware pipeline
  case config.middlewares {
    [] -> core_handler
    mws -> middleware.pipeline(mws, core_handler)
  }
}

/// Handle a WebSocket upgrade request.
fn handle_websocket(
  req: Request(mist.Connection),
  config: TransportConfig,
) -> response.Response(mist.ResponseData) {
  let on_event = config.on_event
  let on_connect = config.on_connect
  let on_disconnect = config.on_disconnect

  mist.websocket(
    request: req,
    handler: fn(state: ConnectionState, msg, _conn) {
      case msg {
        mist.Text(text) -> handle_text_message(state, text)
        mist.Binary(_data) -> {
          log.warning(
            "beacon.transport",
            "Unexpected binary frame from " <> state.id,
          )
          mist.continue(state)
        }
        mist.Closed -> {
          log.info("beacon.transport", "Connection closed: " <> state.id)
          mist.stop()
        }
        mist.Shutdown -> {
          log.info("beacon.transport", "Connection shutdown: " <> state.id)
          mist.stop()
        }
        mist.Custom(internal_msg) -> {
          case internal_msg {
            SendPatch(payload, clock) -> {
              send_message(
                state.connection,
                state.id,
                ServerPatch(payload: payload, clock: clock),
              )
              mist.continue(state)
            }
            SendMount(payload) -> {
              send_message(
                state.connection,
                state.id,
                ServerMount(payload: payload),
              )
              mist.continue(state)
            }
            SendError(reason) -> {
              send_message(
                state.connection,
                state.id,
                ServerError(reason: reason),
              )
              mist.continue(state)
            }
            SendModelSync(model_json, version, ack_clock) -> {
              send_message(
                state.connection,
                state.id,
                ServerModelSync(
                  model_json: model_json,
                  version: version,
                  ack_clock: ack_clock,
                ),
              )
              mist.continue(state)
            }
          }
        }
      }
    },
    on_init: fn(conn) {
      let conn_id = generate_connection_id()
      log.info("beacon.transport", "New connection: " <> conn_id)
      let subject = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(subject)
      // Use runtime_factory if available (per-connection runtimes)
      // Otherwise fall back to shared callbacks
      let #(conn_on_event, conn_on_close) =
        case config.runtime_factory {
          Some(factory) -> {
            // Factory creates a new runtime for this connection
            // Returns per-connection event and disconnect handlers
            let #(evt_handler, close_handler) = factory(conn_id, subject)
            #(evt_handler, close_handler)
          }
          None -> {
            // Shared runtime — use the global callbacks
            on_connect(conn_id, subject)
            #(on_event, on_disconnect)
          }
        }
      let state =
        ConnectionState(
          id: conn_id,
          connection: conn,
          on_event: conn_on_event,
          on_close: conn_on_close,
        )
      pubsub.subscribe("beacon:patches:" <> conn_id)
      #(state, Some(selector))
    },
    on_close: fn(state) {
      log.info("beacon.transport", "Connection closed (cleanup): " <> state.id)
      pubsub.unsubscribe("beacon:patches:" <> state.id)
      state.on_close(state.id)
    },
  )
}

/// Serve the HTML page. Uses SSR-rendered HTML if available,
/// otherwise falls back to a minimal page with empty app root.
fn serve_page(
  page_html: option.Option(String),
) -> response.Response(mist.ResponseData) {
  let html = case page_html {
    option.Some(rendered) -> rendered
    option.None -> default_page_html()
  }
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html)))
}

/// Default page when no SSR is configured.
fn default_page_html() -> String {
  "<!DOCTYPE html>"
  <> "<html><head><meta charset=\"utf-8\"><title>Beacon</title>"
  <> "<style>"
  <> "body{font-family:system-ui,sans-serif;max-width:600px;margin:2rem auto}"
  <> "button{font-size:1.5rem;padding:.5rem 1.5rem;margin:.25rem;cursor:pointer}"
  <> ".counter{text-align:center}"
  <> "</style>"
  <> "</head><body>"
  <> "<div id=\"beacon-app\"></div>"
  <> "<script src=\"/beacon.js\" data-beacon-auto></script>"
  <> "</body></html>"
}

/// Serve the Beacon client JS runtime.
fn serve_js() -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "application/javascript; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(beacon_client_js())))
}

/// The embedded Beacon client JavaScript runtime.
/// Embedded as a string constant so no file serving is needed.
/// Reference: Lustre embeds its client runtime the same way.
///
/// Hydration support: if appRoot already has content (SSR), the first mount
/// just attaches event listeners without replacing innerHTML. This prevents
/// the flash-of-empty-content that would occur if we destroyed the SSR HTML.
fn beacon_client_js() -> String {
  "(function(){\"use strict\";var ws=null,heartbeatTimer=null,reconnectAttempts=0,appRoot=null,hydrated=false,eventClock=0,cachedS=null,cachedD=[],pendingEv=[],domSnap={};function init(opts){opts=opts||{};var rootSelector=opts.rootSelector||\"#beacon-app\";var wsUrl=opts.wsUrl||(location.protocol===\"https:\"?\"wss://\":\"ws://\")+location.host+\"/ws\";appRoot=document.querySelector(rootSelector);if(!appRoot){console.error(\"[beacon] Root not found:\"+rootSelector);return}hydrated=appRoot.childNodes.length>0;if(hydrated){attachEvents()}connect(wsUrl)}function connect(wsUrl){ws=new WebSocket(wsUrl);ws.onopen=function(){reconnectAttempts=0;startHeartbeat();var token=appRoot?appRoot.getAttribute(\"data-beacon-token\")||\"\":\"\";send({type:\"join\",token:token})};ws.onmessage=function(e){handleMessage(e.data)};ws.onclose=function(){stopHeartbeat();scheduleReconnect(wsUrl)};ws.onerror=function(e){console.error(\"[beacon] WS error:\",e)}}function send(msg){if(ws&&ws.readyState===WebSocket.OPEN)ws.send(JSON.stringify(msg))}function startHeartbeat(){stopHeartbeat();heartbeatTimer=setInterval(function(){send({type:\"heartbeat\"})},30000)}function stopHeartbeat(){if(heartbeatTimer){clearInterval(heartbeatTimer);heartbeatTimer=null}}function scheduleReconnect(wsUrl){var delay=Math.min(1000*Math.pow(2,reconnectAttempts),30000);reconnectAttempts++;setTimeout(function(){connect(wsUrl)},delay)}function handleMessage(raw){var msg;try{msg=JSON.parse(raw)}catch(e){return}switch(msg.type){case\"mount\":handleMount(msg.payload);break;case\"patch\":ackClock(msg.clock||0);handlePatch(msg.payload);break;case\"heartbeat_ack\":break;case\"error\":console.error(\"[beacon] Server error:\",msg.reason);break}}function exD(d){var r=[];var i=0;while(d.hasOwnProperty(String(i))){r.push(d[String(i)]);i++}return r}function zipSD(s,d){var h=\"\";for(var i=0;i<s.length;i++){h+=s[i];if(i<d.length)h+=d[i]}return h}function handleMount(payload){if(!appRoot)return;if(hydrated){hydrated=false;try{var d=JSON.parse(payload);if(d&&d.s){cachedS=d.s;cachedD=exD(d)}}catch(e){}attachEvents();return}try{var d=JSON.parse(payload);if(d&&d.s){cachedS=d.s;cachedD=exD(d);morphHTML(appRoot,zipSD(cachedS,cachedD));attachEvents();return}}catch(e){}morphHTML(appRoot,payload);attachEvents()}function handlePatch(payload){if(!appRoot)return;try{var d=JSON.parse(payload);if(Array.isArray(d)){applyPatches(d);return}if(d&&d.s){cachedS=d.s;cachedD=exD(d);morphHTML(appRoot,zipSD(cachedS,cachedD));attachEvents();return}if(d&&cachedS){for(var k in d){if(k!==\"s\"){var idx=parseInt(k,10);if(!isNaN(idx))cachedD[idx]=d[k]}}morphHTML(appRoot,zipSD(cachedS,cachedD));attachEvents();return}}catch(e){}morphHTML(appRoot,payload);attachEvents()}function morphHTML(container,html){var t=document.createElement(\"template\");t.innerHTML=html;morphCh(container,t.content)}function morphCh(op,np){var oc=op.firstChild,nc=np.firstChild;while(nc){if(!oc){op.appendChild(nc.cloneNode(true));nc=nc.nextSibling;continue}if(sameN(oc,nc)){morphN(oc,nc);oc=oc.nextSibling;nc=nc.nextSibling;continue}var m=findM(oc.nextSibling,nc);if(m){while(oc&&oc!==m){var nx=oc.nextSibling;op.removeChild(oc);oc=nx}if(oc){morphN(oc,nc);oc=oc.nextSibling}nc=nc.nextSibling;continue}op.insertBefore(nc.cloneNode(true),oc);nc=nc.nextSibling}while(oc){var nx2=oc.nextSibling;op.removeChild(oc);oc=nx2}}function morphN(o,n){if(o.nodeType===3){if(o.textContent!==n.textContent)o.textContent=n.textContent;return}if(o.nodeType!==1)return;morphA(o,n);var tag=o.tagName;if((tag===\"INPUT\"||tag===\"TEXTAREA\"||tag===\"SELECT\")&&o===document.activeElement)return;morphCh(o,n)}function morphA(o,n){var oa=o.attributes;for(var i=oa.length-1;i>=0;i--){if(!n.hasAttribute(oa[i].name))o.removeAttribute(oa[i].name)}var na=n.attributes;for(var j=0;j<na.length;j++){if(o.getAttribute(na[j].name)!==na[j].value)o.setAttribute(na[j].name,na[j].value)}}function sameN(a,b){if(a.nodeType!==b.nodeType)return false;if(a.nodeType===3)return true;if(a.nodeType!==1)return false;if(a.tagName!==b.tagName)return false;if(a.id&&b.id)return a.id===b.id;return true}function findM(s,n){var c=s,k=5;while(c&&k>0){if(sameN(c,n))return c;c=c.nextSibling;k--}return null}function applyPatches(patches){for(var i=0;i<patches.length;i++)applyPatch(patches[i]);attachEvents()}function applyPatch(p){var node=resolveNode(p.path);if(!node)return;switch(p.op){case\"replace_text\":node.textContent=p.content;break;case\"replace_node\":var nn=createNode(p.node);if(node.parentNode)node.parentNode.replaceChild(nn,node);break;case\"insert_child\":var nc=createNode(p.node);var ref=node.childNodes[p.index]||null;node.insertBefore(nc,ref);break;case\"remove_child\":var ch=node.childNodes[p.index];if(ch)node.removeChild(ch);break;case\"set_attr\":if(node.setAttribute)node.setAttribute(p.name,p.value);break;case\"remove_attr\":if(node.removeAttribute)node.removeAttribute(p.name);break;case\"set_event\":if(node.setAttribute)node.setAttribute(\"data-beacon-event-\"+p.event,p.handler);break;case\"remove_event\":if(node.removeAttribute)node.removeAttribute(\"data-beacon-event-\"+p.event);break}}function resolveNode(path){var n=appRoot;for(var i=0;i<path.length;i++){if(!n||path[i]>=n.childNodes.length)return null;n=n.childNodes[path[i]]}return n}function createNode(j){if(j.t===\"text\")return document.createTextNode(j.c);if(j.t===\"el\"){var el=document.createElement(j.tag);if(j.a)for(var i=0;i<j.a.length;i++){var a=j.a[i];if(a.t===\"attr\")el.setAttribute(a.n,a.v);else if(a.t===\"event\")el.setAttribute(\"data-beacon-event-\"+a.n,a.h)}if(j.ch)for(var c=0;c<j.ch.length;c++)el.appendChild(createNode(j.ch[c]));return el}return document.createTextNode(\"\")}function attachEvents(){if(!appRoot)return;appRoot.onclick=function(e){var t=e.target;while(t&&t!==appRoot){if(t.hasAttribute&&t.hasAttribute(\"data-beacon-event-click\")){e.preventDefault();eventClock++;domSnap[eventClock]=appRoot.innerHTML;pendingEv.push(eventClock);send({type:\"event\",name:\"click\",handler_id:t.getAttribute(\"data-beacon-event-click\"),data:\"{}\",target_path:getPath(t),clock:eventClock});return}t=t.parentNode}};appRoot.oninput=function(e){var t=e.target;while(t&&t!==appRoot){if(t.hasAttribute&&t.hasAttribute(\"data-beacon-event-input\")){eventClock++;domSnap[eventClock]=appRoot.innerHTML;pendingEv.push(eventClock);send({type:\"event\",name:\"input\",handler_id:t.getAttribute(\"data-beacon-event-input\"),data:JSON.stringify({value:t.value||\"\"}),target_path:getPath(t),clock:eventClock});return}t=t.parentNode}}}function getPath(node){var parts=[];var c=node;while(c&&c!==appRoot){var p=c.parentNode;if(p){var ch=p.childNodes;for(var i=0;i<ch.length;i++)if(ch[i]===c){parts.unshift(i);break}}c=p}return parts.join(\".\")}function ackClock(c){if(c<=0)return;pendingEv=pendingEv.filter(function(v){return v>c});var ks=Object.keys(domSnap).map(Number);for(var i=0;i<ks.length;i++){if(ks[i]<=c)delete domSnap[ks[i]]}}window.Beacon={init:init};if(document.currentScript&&document.currentScript.hasAttribute(\"data-beacon-auto\"))document.addEventListener(\"DOMContentLoaded\",function(){init()})})();"
}


/// Start the transport layer — binds to the given port and begins
/// accepting connections. Returns the supervisor's Pid for monitoring.
pub fn start(
  config: TransportConfig,
) -> Result(process.Pid, error.BeaconError) {
  log.info(
    "beacon.transport",
    "Starting on port " <> int.to_string(config.port),
  )
  let handler = create_handler(config)
  let result =
    mist.new(handler)
    |> mist.port(config.port)
    |> mist.start
  case result {
    Ok(started) -> {
      log.info(
        "beacon.transport",
        "Listening on port " <> int.to_string(config.port),
      )
      Ok(started.pid)
    }
    Error(_start_error) -> {
      log.error(
        "beacon.transport",
        "Failed to start on port " <> int.to_string(config.port),
      )
      Error(error.TransportError(
        reason: "Failed to bind to port " <> int.to_string(config.port),
      ))
    }
  }
}
