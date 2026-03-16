import beacon/effect
import beacon/element
import beacon/ssr

// --- Test helpers ---

pub type TestModel {
  TestModel(name: String)
}

pub type TestMsg {
  NoOp
}

fn test_init() -> #(TestModel, effect.Effect(TestMsg)) {
  #(TestModel(name: "World"), effect.none())
}

fn test_view(model: TestModel) -> element.Node(TestMsg) {
  element.el("div", [], [
    element.el("h1", [], [element.text("Hello, " <> model.name <> "!")]),
  ])
}

fn test_config() -> ssr.SsrConfig(TestModel, TestMsg) {
  ssr.SsrConfig(
    init: test_init,
    view: test_view,
    secret_key: "test-secret-key-at-least-32-chars-long!!",
    title: "Test Page",
  )
}

// --- Tests ---

pub fn render_page_produces_html_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "<!DOCTYPE html>")
  let assert True = str_contains(page.html, "<html>")
  let assert True = str_contains(page.html, "</html>")
}

pub fn render_page_includes_view_content_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "Hello, World!")
}

pub fn render_page_includes_title_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "<title>Test Page</title>")
}

pub fn render_page_includes_script_tag_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "<script src=\"/beacon_client.js\"")
  let assert True = str_contains(page.html, "data-beacon-auto")
}

pub fn render_page_includes_beacon_app_root_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "id=\"beacon-app\"")
}

pub fn render_page_includes_session_token_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "data-beacon-token=\"")
  // Token should be non-empty
  let assert True = string_length(page.session_token) > 10
}

pub fn render_page_view_inside_app_root_test() {
  let page = ssr.render_page(test_config())
  // The view HTML should be inside the beacon-app div
  let assert True = str_contains(page.html, "id=\"beacon-app\"")
  let assert True = str_contains(page.html, "<h1>Hello, World!</h1>")
}

// --- Session token tests ---

pub fn create_session_token_not_empty_test() {
  let token = ssr.create_session_token("my-secret-key-for-testing-purposes!!")
  let assert True = string_length(token) > 10
}

pub fn verify_valid_token_test() {
  let secret = "my-secret-key-for-testing-purposes!!"
  let token = ssr.create_session_token(secret)
  let assert Ok(_ts) = ssr.verify_session_token(token, secret, 3600)
}

pub fn verify_token_wrong_secret_test() {
  let token = ssr.create_session_token("correct-secret-key-for-signing!!")
  let assert Error(_) =
    ssr.verify_session_token(token, "wrong-secret-key-for-verifying!!!", 3600)
}

pub fn verify_expired_token_test() {
  let secret = "my-secret-key-for-testing-purposes!!"
  let token = ssr.create_session_token(secret)
  // Use max_age of -1 seconds — token is already "expired"
  let assert Error("Session token expired") =
    ssr.verify_session_token(token, secret, -1)
}

pub fn verify_tampered_token_test() {
  let secret = "my-secret-key-for-testing-purposes!!"
  let token = ssr.create_session_token(secret)
  // Tamper with the token
  let tampered = token <> "x"
  let assert Error(_) = ssr.verify_session_token(tampered, secret, 3600)
}

pub fn to_response_returns_200_test() {
  let page = ssr.render_page(test_config())
  let resp = ssr.to_response(page)
  let assert 200 = resp.status
}

// --- Helpers ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool

fn string_length(s: String) -> Int {
  do_string_length(s)
}

@external(erlang, "erlang", "byte_size")
fn do_string_length(s: String) -> Int
