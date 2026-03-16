/// Tests for the dev module's file watching and hot reload utilities.

pub fn find_gleam_files_test() {
  // The src directory should contain .gleam files
  let files = find_gleam_files("src")
  let assert True = length(files) > 0
}

pub fn check_no_changes_initially_test() {
  // First call establishes baseline, second should show no changes
  let _ = get_timestamps(["src"])
  let assert False = check_changes(["src"])
}

pub fn native_watcher_check_test() {
  // Should return a Bool without crashing
  let available = native_available()
  let assert True = available == True || available == False
}

@external(erlang, "beacon_dev_ffi", "native_watcher_available")
fn native_available() -> Bool

@external(erlang, "beacon_dev_ffi", "get_file_timestamps")
fn get_timestamps(dirs: List(String)) -> List(#(String, Int))

@external(erlang, "beacon_dev_ffi", "check_for_changes")
fn check_changes(dirs: List(String)) -> Bool

@external(erlang, "beacon_dev_ffi", "find_gleam_files")
fn find_gleam_files(dir: String) -> List(String)

fn length(list: List(a)) -> Int {
  do_length(list, 0)
}

fn do_length(list: List(a), acc: Int) -> Int {
  case list {
    [] -> acc
    [_, ..rest] -> do_length(rest, acc + 1)
  }
}
