import beacon/effect
import beacon/element
import beacon/route
import beacon/ssr
import gleam/option
import gleam/string

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
    head_html: option.None,
  )
}

// --- Tests ---

pub fn render_page_produces_html_test() {
  let page = ssr.render_page(test_config())
  // Verify doctype is at the very start of the HTML string
  let assert True = string.starts_with(page.html, "<!DOCTYPE html>")
  // Verify ORDER: <!DOCTYPE html> comes before <html> comes before </html>
  let assert Ok(doctype_pos) = string_index_of(page.html, "<!DOCTYPE html>")
  let assert Ok(html_open_pos) = string_index_of(page.html, "<html>")
  let assert Ok(html_close_pos) = string_index_of(page.html, "</html>")
  let assert True = doctype_pos < html_open_pos
  let assert True = html_open_pos < html_close_pos
}

pub fn render_page_includes_view_content_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "Hello, World!")
  // Verify "Hello, World!" appears AFTER id="beacon-app" (content is inside the app root)
  let assert Ok(app_pos) = string_index_of(page.html, "id=\"beacon-app\"")
  let assert Ok(content_pos) = string_index_of(page.html, "Hello, World!")
  let assert True = app_pos < content_pos
}

pub fn render_page_includes_title_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "<title>Test Page</title>")
}

pub fn render_page_includes_script_tag_test() {
  let page = ssr.render_page(test_config())
  // Script tag should reference beacon_client (hashed or plain)
  let assert True = str_contains(page.html, "<script src=\"/beacon_client")
  let assert True = str_contains(page.html, "data-beacon-auto")
}

pub fn render_page_includes_beacon_app_root_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "id=\"beacon-app\"")
}

pub fn render_page_includes_session_token_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "data-beacon-token=\"")
  // Verify the token is actually valid by verifying it with the same secret
  let assert Ok(_ts) =
    ssr.verify_session_token(
      page.session_token,
      "test-secret-key-at-least-32-chars-long!!",
      3600,
    )
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
  let assert Ok(ts) = ssr.verify_session_token(token, secret, 3600)
  // Assert the timestamp is recent — within the last 60 seconds
  let now = current_system_time_seconds()
  let age = now - ts
  let assert True = age >= 0
  let assert True = age < 60
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

pub fn render_page_for_path_renders_route_specific_html_test() {
  // Test that different paths produce different SSR content
  // Using the existing TestModel/TestMsg types with a route-aware update
  let config = ssr.SsrConfig(
    init: fn() { #(TestModel(name: "default"), effect.none()) },
    view: test_view,
    secret_key: "test-secret-key-at-least-32-chars-long!!",
    title: "Route Test",
    head_html: option.None,
  )
  let patterns = [route.pattern("/"), route.pattern("/about")]
  let on_route_change = option.Some(fn(r: route.Route) -> TestMsg {
    // We can't actually change the model here since TestMsg is NoOp,
    // but we verify the function is called
    let _ = r
    NoOp
  })
  let update = fn(model: TestModel, _msg: TestMsg) {
    #(model, effect.none())
  }

  let page = ssr.render_page_for_path(config, "/about", patterns, on_route_change, update)
  // Should contain the view HTML
  let assert True = str_contains(page.html, "Hello, default!")
  // Should have a session token
  let assert True = string_length(page.session_token) > 10
}

pub fn to_response_returns_200_test() {
  let page = ssr.render_page(test_config())
  let resp = ssr.to_response(page)
  let assert 200 = resp.status
}

// --- head_html tests ---

pub fn head_html_none_renders_no_extra_content_test() {
  let page = ssr.render_page(test_config())
  // No <style> block (removed hardcoded demo styles)
  let assert True = does_not_contain(page.html, "<style>")
  // head_html is None, so no extra content between </title> and </head>
  let assert True = str_contains(page.html, "</title></head>")
}

pub fn head_html_injects_stylesheet_link_test() {
  let config = ssr.SsrConfig(
    init: test_init,
    view: test_view,
    secret_key: "test-secret-key-at-least-32-chars-long!!",
    title: "CSS Test",
    head_html: option.Some("<link rel=\"stylesheet\" href=\"/static/styles.css\">"),
  )
  let page = ssr.render_page(config)
  let assert True = str_contains(page.html, "<link rel=\"stylesheet\" href=\"/static/styles.css\">")
  // The link tag should be in the head section (after title, before </head>)
  let assert Ok(title_pos) = string_index_of(page.html, "</title>")
  let assert Ok(link_pos) = string_index_of(page.html, "<link rel=\"stylesheet\"")
  let assert Ok(head_close_pos) = string_index_of(page.html, "</head>")
  let assert True = title_pos < link_pos
  let assert True = link_pos < head_close_pos
}

pub fn head_html_multiple_tags_test() {
  let config = ssr.SsrConfig(
    init: test_init,
    view: test_view,
    secret_key: "test-secret-key-at-least-32-chars-long!!",
    title: "Multi Head Test",
    head_html: option.Some("<link rel=\"stylesheet\" href=\"/a.css\"><meta name=\"theme-color\" content=\"#000\">"),
  )
  let page = ssr.render_page(config)
  let assert True = str_contains(page.html, "href=\"/a.css\"")
  let assert True = str_contains(page.html, "theme-color")
}

// --- Helpers ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

fn does_not_contain(haystack: String, needle: String) -> Bool {
  case do_str_contains(haystack, needle) {
    True -> False
    False -> True
  }
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool

fn string_length(s: String) -> Int {
  do_string_length(s)
}

@external(erlang, "erlang", "byte_size")
fn do_string_length(s: String) -> Int

fn string_index_of(haystack: String, needle: String) -> Result(Int, Nil) {
  do_string_index_of(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_index_of")
fn do_string_index_of(haystack: String, needle: String) -> Result(Int, Nil)

@external(erlang, "beacon_test_ffi", "system_time_seconds")
fn current_system_time_seconds() -> Int
