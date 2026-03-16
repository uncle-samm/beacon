import * as $int from "../gleam_stdlib/gleam/int.mjs";
import * as $handler from "./beacon_client/handler.mjs";
import {
  morph_html as morph_app_root_ffi,
  query_selector,
  ws_send,
  ws_connect as connect_ws,
  log,
} from "./beacon_client_ffi.mjs";
import { Ok, CustomType as $CustomType } from "./gleam.mjs";

export class ClientState extends $CustomType {
  constructor(model, local, update, view, handler_registry, model_version, event_clock, msg_affects_model) {
    super();
    this.model = model;
    this.local = local;
    this.update = update;
    this.view = view;
    this.handler_registry = handler_registry;
    this.model_version = model_version;
    this.event_clock = event_clock;
    this.msg_affects_model = msg_affects_model;
  }
}
export const ClientState$ClientState = (model, local, update, view, handler_registry, model_version, event_clock, msg_affects_model) =>
  new ClientState(model,
  local,
  update,
  view,
  handler_registry,
  model_version,
  event_clock,
  msg_affects_model);
export const ClientState$isClientState = (value) =>
  value instanceof ClientState;
export const ClientState$ClientState$model = (value) => value.model;
export const ClientState$ClientState$0 = (value) => value.model;
export const ClientState$ClientState$local = (value) => value.local;
export const ClientState$ClientState$1 = (value) => value.local;
export const ClientState$ClientState$update = (value) => value.update;
export const ClientState$ClientState$2 = (value) => value.update;
export const ClientState$ClientState$view = (value) => value.view;
export const ClientState$ClientState$3 = (value) => value.view;
export const ClientState$ClientState$handler_registry = (value) =>
  value.handler_registry;
export const ClientState$ClientState$4 = (value) => value.handler_registry;
export const ClientState$ClientState$model_version = (value) =>
  value.model_version;
export const ClientState$ClientState$5 = (value) => value.model_version;
export const ClientState$ClientState$event_clock = (value) => value.event_clock;
export const ClientState$ClientState$6 = (value) => value.event_clock;
export const ClientState$ClientState$msg_affects_model = (value) =>
  value.msg_affects_model;
export const ClientState$ClientState$7 = (value) => value.msg_affects_model;

function morph_app_root(html) {
  let $ = query_selector("#beacon-app");
  if ($ instanceof Ok) {
    let el = $[0];
    return morph_app_root_ffi(el, html);
  } else {
    return undefined;
  }
}

function attach_events() {
  return undefined;
}

/**
 * Handle authoritative Model from server.
 */
export function handle_model_sync(state, new_model, version) {
  $handler.start_render();
  let html = state.view(new_model, state.local);
  let new_registry = $handler.finish_render();
  morph_app_root(html);
  let $ = attach_events();
  
  log("Model sync v" + $int.to_string(version));
  return new ClientState(
    new_model,
    state.local,
    state.update,
    state.view,
    new_registry,
    version,
    state.event_clock,
    state.msg_affects_model,
  );
}

function get_ws_url() {
  return "ws://localhost:8080/ws";
}

/**
 * Initialize the client runtime.
 */
export function init(model, local, update, view, msg_affects_model) {
  $handler.start_render();
  let html = view(model, local);
  let registry = $handler.finish_render();
  morph_app_root(html);
  let $ = attach_events();
  
  let ws_url = get_ws_url();
  connect_ws(ws_url);
  return new ClientState(
    model,
    local,
    update,
    view,
    registry,
    0,
    0,
    msg_affects_model,
  );
}

function send_model_update(handler_id, data, clock) {
  let msg = ((((("{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"" + handler_id) + "\",\"data\":") + data) + ",\"target_path\":\"0\",\"clock\":") + $int.to_string(
    clock,
  )) + "}";
  return ws_send(msg);
}

/**
 * Handle an event from the DOM.
 */
export function handle_event(state, handler_id, event_data) {
  let $ = $handler.resolve(state.handler_registry, handler_id, event_data);
  if ($ instanceof Ok) {
    let msg = $[0];
    let $1 = state.update(state.model, state.local, msg);
    let new_model;
    let new_local;
    new_model = $1[0];
    new_local = $1[1];
    $handler.start_render();
    let html = state.view(new_model, new_local);
    let new_registry = $handler.finish_render();
    morph_app_root(html);
    let $2 = attach_events();
    
    let new_clock = state.event_clock + 1;
    let $3 = state.msg_affects_model(msg);
    if ($3) {
      send_model_update(handler_id, event_data, new_clock);
      log(("Event " + handler_id) + " → server (model changed)")
    } else {
      log(("Event " + handler_id) + " → local only")
    }
    return new ClientState(
      new_model,
      new_local,
      state.update,
      state.view,
      new_registry,
      state.model_version,
      new_clock,
      state.msg_affects_model,
    );
  } else {
    let reason = $[0];
    log("Handler error: " + reason);
    return state;
  }
}
