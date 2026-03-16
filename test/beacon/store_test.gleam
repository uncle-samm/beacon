import beacon/store
import gleam/int

pub fn store_put_and_get_test() {
  let s = store.new("test_store_" <> uid())
  store.put(s, "key1", "value1")
  let assert Ok("value1") = store.get(s, "key1")
}

pub fn store_get_missing_test() {
  let s = store.new("test_store_miss_" <> uid())
  let assert Error(Nil) = store.get(s, "nope")
}

pub fn store_delete_test() {
  let s = store.new("test_store_del_" <> uid())
  store.put(s, "k", "v")
  store.delete(s, "k")
  let assert Error(Nil) = store.get(s, "k")
}

pub fn store_count_test() {
  let s = store.new("test_store_cnt_" <> uid())
  let assert 0 = store.count(s)
  store.put(s, "a", "1")
  store.put(s, "b", "2")
  let assert 2 = store.count(s)
}

pub fn list_store_append_and_get_all_test() {
  let s = store.new_list("test_ls_" <> uid())
  store.append(s, "room1", "msg_a")
  store.append(s, "room1", "msg_b")
  store.append(s, "room1", "msg_c")
  let msgs = store.get_all(s, "room1")
  let assert 3 = list_length(msgs)
}

pub fn list_store_different_keys_test() {
  let s = store.new_list("test_ls_keys_" <> uid())
  store.append(s, "general", "hello")
  store.append(s, "random", "world")
  let assert 1 = list_length(store.get_all(s, "general"))
  let assert 1 = list_length(store.get_all(s, "random"))
}

pub fn list_store_empty_key_test() {
  let s = store.new_list("test_ls_empty_" <> uid())
  let assert [] = store.get_all(s, "empty")
}

pub fn list_store_delete_all_test() {
  let s = store.new_list("test_ls_delall_" <> uid())
  store.append(s, "k", "a")
  store.append(s, "k", "b")
  store.delete_all(s, "k")
  let assert [] = store.get_all(s, "k")
}

fn uid() -> String {
  int.to_string(erlang_unique())
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique() -> Int

fn list_length(l: List(a)) -> Int {
  do_list_length(l, 0)
}

fn do_list_length(l: List(a), acc: Int) -> Int {
  case l {
    [] -> acc
    [_, ..rest] -> do_list_length(rest, acc + 1)
  }
}
