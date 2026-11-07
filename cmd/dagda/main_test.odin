package main

import "core:mem/virtual"
import "core:os"
import "core:testing"

TEST_ODIN :: #config(DAGDA_TEST_ODIN, "")

@(test)
names_paths_and_checksums :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    context.temp_allocator = context.allocator
    testing.expect(t, valid_name("billing_api2"))
    for value in ([]string{"", "../billing", "/billing", "billing;touch", "billing name", "Bill", "2billing", "billing-name"}) {
        testing.expect(t, !valid_name(value), value)
    }
    for value in ([]string{"../file", "/file", "a/../b", "a//b", "a\\b", "a/./b", "a\n"}) {
        testing.expect(t, !safe_relative(value), value)
    }
    testing.expect(t, safe_relative("dagda/http/http.odin"))
    testing.expect_value(t, hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    testing.expect_value(t, run({"unknown"}), 2)
    testing.expect_value(t, run({"build", "--unknown"}), 2)
}

@(test)
generation_is_exclusive_and_detects_vendor_drift :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    context.temp_allocator = context.allocator
    parent, error := os.make_directory_temp("/tmp", "dagda-cli-unit-", context.allocator)
    testing.expect(t, error == nil)
    if error != nil { return }
    defer os.remove_all(parent)
    bundle := load_bundle()
    testing.expect_value(t, create_project(&bundle, parent, "preview", true), 0)
    testing.expect(t, !exists(path(parent, "preview")))
    testing.expect_value(t, create_project(&bundle, parent, "billing"), 0)
    root := path(parent, "billing")
    _, _, ok := load_project(root)
    testing.expect(t, ok)
    sentinel := path(root, "app/routes.odin")
    bytes, read_error := os.read_entire_file(sentinel, context.allocator)
    testing.expect(t, read_error == nil)
    digest := hash(string(bytes))
    testing.expect_value(t, create_project(&bundle, parent, "billing"), 1)
    after, _ := os.read_entire_file(sentinel, context.allocator)
    testing.expect_value(t, hash(string(after)), digest)
    testing.expect(t, write_new(path(root, "vendor/dagda/unexpected.odin"), "package unexpected"))
    _, _, ok = load_project(root)
    testing.expect(t, !ok)
    testing.expect(t, os.remove(path(root, "vendor/dagda/unexpected.odin")) == nil)
    // Even a link to the correct bytes is rejected in the pinned source tree.
    locked := path(root, "vendor/dagda/native/platform.c")
    saved, saved_error := os.read_entire_file(locked, context.allocator)
    testing.expect(t, saved_error == nil)
    testing.expect(t, write_new(path(parent, "platform.c"), string(saved)))
    testing.expect(t, os.remove(locked) == nil)
    testing.expect(t, os.symlink(path(parent, "platform.c"), locked) == nil)
    _, _, ok = load_project(root)
    testing.expect(t, !ok)
    testing.expect(t, os.remove(locked) == nil)
    testing.expect(t, write_new(locked, "changed"))
    _, _, ok = load_project(root)
    testing.expect(t, !ok)
}

@(test)
generated_project_builds_and_runs_odin_tests :: proc(t: ^testing.T) {
    if TEST_ODIN == "" { testing.expect(t, false, "Run scripts/test-unit.sh to supply the pinned compiler"); return }
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    context.temp_allocator = context.allocator
    parent, error := os.make_directory_temp("/tmp", "dagda-cli-build-", context.allocator)
    testing.expect(t, error == nil)
    if error != nil { return }
    defer os.remove_all(parent)
    // Shell-sensitive characters are ordinary path data, never command text.
    spaced := path(parent, "space $ parent")
    testing.expect(t, ensure_directory(spaced))
    bundle := load_bundle()
    testing.expect_value(t, create_project(&bundle, spaced, "billing"), 0)
    root := path(spaced, "billing")
    project, lock, ok := load_project(root)
    testing.expect(t, ok)
    if !ok { return }
    testing.expect_value(t, build_project(root, &project, &lock, TEST_ODIN, quiet=true), 0)
    testing.expect(t, regular(path(root, "build/billing")))
    testing.expect_value(t, build_project(root, &project, &lock, TEST_ODIN, test=true, quiet=true), 0)
    testing.expect(t, write_new(path(root, "app/failing_test.odin"), "package main\nimport \"core:testing\"\n@(test) failure :: proc(t: ^testing.T) { testing.expect(t, false) }\n"))
    testing.expect(t, build_project(root, &project, &lock, TEST_ODIN, test=true, quiet=true) != 0)
    testing.expect(t, write_new(path(root, "app/broken.odin"), "not valid Odin"))
    testing.expect(t, build_project(root, &project, &lock, TEST_ODIN, quiet=true) != 0)
}
