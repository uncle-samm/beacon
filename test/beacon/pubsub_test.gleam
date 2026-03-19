import beacon/pubsub
import gleam/erlang/process
import gleam/list

pub fn start_test() {
  pubsub.start()
  // Verify it's functional — subscriber count for a new topic should be 0
  let assert 0 = pubsub.subscriber_count("nonexistent_topic_start_test")
}

pub fn subscribe_and_broadcast_test() {
  pubsub.start()
  let topic = "broadcast_test_" <> unique_id()

  // Spawn 3 subscriber processes, each signals when ready
  let ready_subject = process.new_subject()
  let count = 3

  list.repeat(Nil, count)
  |> list.each(fn(_) {
    let _ =
      process.spawn(fn() {
        pubsub.subscribe(topic)
        // Signal that subscription is complete
        process.send(ready_subject, "ready")
        // Stay alive long enough for the test to complete
        process.sleep(5000)
      })
  })

  // Wait for all 3 subscribers to be ready
  let selector =
    process.new_selector()
    |> process.select(ready_subject)
  let assert Ok("ready") = process.selector_receive(selector, 1000)
  let assert Ok("ready") = process.selector_receive(selector, 1000)
  let assert Ok("ready") = process.selector_receive(selector, 1000)

  // Verify subscriber count is correct
  let assert 3 = pubsub.subscriber_count(topic)

  // Broadcast a message (this uses pg to send to all members)
  pubsub.broadcast(topic, "hello")

  // Verify broadcast didn't crash and subscriber count is maintained
  process.sleep(100)
  let assert 3 = pubsub.subscriber_count(topic)
}

pub fn subscriber_count_zero_test() {
  pubsub.start()
  let assert 0 = pubsub.subscriber_count("empty_topic_xyz")
}

pub fn subscriber_count_after_join_test() {
  pubsub.start()
  let topic = "count_test_topic"
  let _ =
    process.spawn(fn() {
      pubsub.subscribe(topic)
      process.sleep(2000)
    })
  process.sleep(50)
  let assert 1 = pubsub.subscriber_count(topic)
}

pub fn multiple_subscribers_count_test() {
  pubsub.start()
  let topic = "multi_count_topic"
  let _ =
    process.spawn(fn() {
      pubsub.subscribe(topic)
      process.sleep(2000)
    })
  let _ =
    process.spawn(fn() {
      pubsub.subscribe(topic)
      process.sleep(2000)
    })
  let _ =
    process.spawn(fn() {
      pubsub.subscribe(topic)
      process.sleep(2000)
    })
  process.sleep(50)
  let assert 3 = pubsub.subscriber_count(topic)
}

fn unique_id() -> String {
  do_unique_id()
}

@external(erlang, "beacon_test_ffi", "unique_ref")
fn do_unique_id() -> String
