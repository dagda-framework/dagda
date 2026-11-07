package main

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

VERSION :: "0.1.0-dev"
BUNDLE_JSON :: #load("../../build/cli-bundle.json", string)
Compiler :: struct { version, platform, url, sha256, compiler_version: string }
File :: struct { path, content, sha256: string }
Bundle :: struct { format: int, revision, source_id: string, compiler: Compiler, files, templates: []File }
Project :: struct { format: int, name: string }
Locked_File :: struct { path, sha256: string }
Lock :: struct { format: int, framework_revision, framework_source_sha256: string, compiler: Compiler, files: []Locked_File }

main :: proc() {
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil { os.exit(1) }
    context.allocator = virtual.arena_allocator(&arena)
    context.temp_allocator = context.allocator
    code := run(os.args[1:])
    virtual.arena_destroy(&arena)
    os.exit(code)
}
help :: proc() {
    fmt.println(`Dagda — Odin backend framework
Usage:
  dagda new NAME [--dry-run]   Generate an independent project; never overwrite
  dagda doctor [--database]  Verify pins, native libraries, and configuration
  dagda build [--release]    Build the app and write build metadata
  dagda test                 Run the application's Odin tests
  dagda --version

Run doctor/build/test from the generated project root.
Compiler: DAGDA_ODIN, then project .tools pin, then odin on PATH.`)
}
problem :: proc(message: string) -> int { fmt.eprintln("dagda:", message); return 1 }
path :: proc(parts: ..string) -> string { value, error := os.join_path(parts, context.allocator); assert(error == nil); return value }
exists :: proc(name: string) -> bool { _, error := os.lstat(name, context.allocator); return error == nil }
regular :: proc(name: string) -> bool { info, error := os.lstat(name, context.allocator); return error == nil && info.type == .Regular }
directory :: proc(name: string) -> bool { info, error := os.lstat(name, context.allocator); return error == nil && info.type == .Directory }
ensure_directory :: proc(name: string) -> bool {
    if exists(name) { return directory(name) }
    return os.make_directory(name) == nil
}
ensure_tree :: proc(name: string) -> bool {
    clean, error := os.clean_path(name, context.allocator)
    if error != nil { return false }
    if exists(clean) { return directory(clean) }
    if !ensure_tree(os.dir(clean)) { return false }
    return os.make_directory(clean) == nil
}
valid_name :: proc(name: string) -> bool {
    if len(name) == 0 || len(name) > 48 || name[0] < 'a' || name[0] > 'z' { return false }
    for ch in name { if !(('a' <= ch && ch <= 'z') || ('0' <= ch && ch <= '9') || ch == '_') { return false } }
    return true
}
safe_relative :: proc(name: string) -> bool {
    if len(name) == 0 || len(name) > 1024 || os.is_absolute_path(name) || strings.contains(name, "\\") { return false }
    for ch in name { if ch < 32 || ch == 127 { return false } }
    for part in strings.split(name, "/", context.allocator) {
        if part == "" || part == "." || part == ".." { return false }
    }
    return true
}
hash :: proc(data: string) -> string {
    state: sha2.Context_256
    sha2.init_256(&state)
    sha2.update(&state, transmute([]byte)data)
    digest: [32]byte
    sha2.final(&state, digest[:])
    return string(hex.encode(digest[:], context.allocator))
}
read_json :: proc(name: string, destination: ^$T) -> bool {
    info, error := os.lstat(name, context.allocator)
    if error != nil || info.type != .Regular || info.size > 2 * 1024 * 1024 { return false }
    bytes, read_error := os.read_entire_file(name, context.allocator)
    if read_error != nil { return false }
    return json.unmarshal(bytes, destination, spec=.JSON, allocator=context.allocator) == nil
}
write_new :: proc(name, content: string) -> bool {
    file, error := os.open(name, {.Write, .Create, .Excl})
    if error != nil { return false }
    defer os.close(file)
    written, write_error := os.write_string(file, content)
    return write_error == nil && written == len(content)
}
write_json :: proc(name: string, value: $T, exclusive := false) -> bool {
    bytes, error := json.marshal(value, {spec=.JSON, pretty=true}, context.allocator)
    if error != nil { return false }
    if exclusive { return write_new(name, string(bytes)) }
    if exists(name) && !regular(name) { return false }
    return os.write_entire_file(name, bytes) == nil
}
load_bundle :: proc() -> Bundle {
    bundle: Bundle
    error := json.unmarshal_string(BUNDLE_JSON, &bundle, spec=.JSON, allocator=context.allocator)
    assert(error == nil && bundle.format == 1)
    return bundle
}

create_project :: proc(bundle: ^Bundle, parent, name: string, preview := false) -> int {
    if !valid_name(name) { return problem("Name must start with a lowercase letter and contain only a-z, 0-9, or _ (maximum 48 characters)") }
    target := path(parent, name)
    if exists(target) { return problem("Destination already exists; no files were changed") }
    if preview {
        fmt.println(path(name, "dagda.json"))
        fmt.println(path(name, "dagda.lock"))
        for file in bundle.templates { fmt.println(path(name, file.path)) }
        for file in bundle.files { fmt.println(path(name, "vendor/dagda", file.path)) }
        return 0
    }
    // Exclusive directory creation closes the initial exists-check race. Writes
    // are also exclusive; a partial failure is preserved, never blindly removed.
    if os.make_directory(target) != nil { return problem("Cannot create destination") }
    for file in bundle.templates {
        if !safe_relative(file.path) { return problem("Invalid embedded template path") }
        destination := path(target, file.path)
        if !ensure_tree(os.dir(destination)) { return problem("Project generation incomplete: cannot create directory") }
        text, _ := strings.replace_all(file.content, "__APP_NAME__", name, context.allocator)
        if !write_new(destination, text) { return problem("Project generation incomplete: cannot create file") }
    }
    lock := Lock{format=1, framework_revision=bundle.revision, framework_source_sha256=bundle.source_id, compiler=bundle.compiler}
    lock.files = make([]Locked_File, len(bundle.files))
    for file, index in bundle.files {
        if !safe_relative(file.path) { return problem("Invalid embedded framework path") }
        destination := path(target, "vendor/dagda", file.path)
        if !ensure_tree(os.dir(destination)) || !write_new(destination, file.content) {
            return problem("Project generation incomplete: cannot copy framework")
        }
        lock.files[index] = {file.path, file.sha256}
    }
    if !write_json(path(target, "dagda.json"), Project{1, name}, true) || !write_json(path(target, "dagda.lock"), lock, true) {
        return problem("Project generation incomplete: cannot create manifests")
    }
    fmt.printf("Created %s\nNext: cd %s && dagda doctor && dagda test && dagda build\n", name, name)
    return 0
}

inventory :: proc(root, relative: string, expected: map[string]string) -> bool {
    entries, error := os.read_all_directory_by_path(path(root, relative), context.allocator)
    if error != nil { return false }
    for entry in entries {
        rel := entry.name if relative == "" else path(relative, entry.name)
        if relative == "" && entry.name == "build" {
            if !directory(path(root, rel)) { return false }
            continue
        }
        info, stat_error := os.lstat(path(root, rel), context.allocator)
        if stat_error != nil { return false }
        #partial switch info.type {
        case .Directory:
            if len(rel) > 1024 || !inventory(root, rel, expected) { return false }
        case .Regular:
            if rel not_in expected { return false }
        case: return false
        }
    }
    return true
}
load_project :: proc(root: string) -> (project: Project, lock: Lock, ok: bool) {
    if !read_json(path(root, "dagda.json"), &project) || project.format != 1 || !valid_name(project.name) {
        problem("Invalid/missing dagda.json; run this command from a generated project root")
        return
    }
    if !read_json(path(root, "dagda.lock"), &lock) || lock.format != 1 || len(lock.files) == 0 || len(lock.files) > 512 ||
       lock.compiler.platform != "linux-amd64" || len(lock.compiler.compiler_version) == 0 || len(lock.compiler.compiler_version) > 80 ||
       !safe_relative(lock.compiler.version) || strings.contains(lock.compiler.version, "/") {
        problem("Invalid or unsupported dagda.lock")
        return
    }
    vendor := path(root, "vendor/dagda")
    if !directory(path(root, "vendor")) || !directory(vendor) { problem("Missing framework directory or unexpected symlink"); return }
    expected := make(map[string]string)
    summary: strings.Builder
    strings.builder_init(&summary, context.allocator)
    for file in lock.files {
        if !safe_relative(file.path) || file.path in expected { problem("Invalid locked file path"); return }
        expected[file.path] = file.sha256
        // Never follow a symlink in a locked source path.
        current := vendor
        parts := strings.split(file.path, "/", context.allocator)
        for part, index in parts {
            current = path(current, part)
            if index < len(parts)-1 && !directory(current) { problem("Locked source directory changed"); return }
        }
        info, stat_error := os.lstat(current, context.allocator)
        if stat_error != nil || info.type != .Regular || info.size > 2 * 1024 * 1024 { problem("Locked source missing or invalid"); return }
        bytes, error := os.read_entire_file(current, context.allocator)
        if error != nil || hash(string(bytes)) != file.sha256 { problem("Framework source checksum mismatch; restore the locked vendor snapshot"); return }
        strings.write_string(&summary, fmt.tprintf("%s\n%s\n", file.path, file.sha256))
    }
    if hash(strings.to_string(summary)) != lock.framework_source_sha256 || !inventory(vendor, "", expected) {
        problem("Framework inventory does not match the lock file")
        return
    }
    return project, lock, true
}

child :: proc(command: []string, root: string, quiet := false) -> (code: int, output: string) {
    if !quiet {
        process, start_error := os.process_start(os.Process_Desc{command=command, working_dir=root, stdout=os.stdout, stderr=os.stderr})
        if start_error != nil { problem("Unable to execute required tool"); return 1, "" }
        state, wait_error := os.process_wait(process)
        if wait_error != nil { problem("Unable to wait for required tool"); return 1, "" }
        return state.exit_code, ""
    }
    state, stdout, _, error := os.process_exec(os.Process_Desc{command=command, working_dir=root}, context.allocator)
    if error != nil { return 1, "" }
    return state.exit_code, string(stdout)
}
compiler_path :: proc(root: string, lock: ^Lock) -> string {
    override := os.get_env("DAGDA_ODIN", context.allocator)
    if override != "" { return override }
    local := path(root, ".tools", fmt.tprintf("odin-%s", lock.compiler.version), "odin")
    if regular(local) { return local }
    return "odin"
}
check_compiler :: proc(root: string, lock: ^Lock) -> (string, bool) {
    compiler := compiler_path(root, lock)
    code, output := child({compiler, "version"}, root, true)
    if code != 0 { problem("Odin unavailable; set DAGDA_ODIN to the pinned compiler executable"); return "", false }
    if !strings.has_suffix(strings.trim_space(output), fmt.tprintf(" version %s", lock.compiler.compiler_version)) {
        problem("Odin version mismatch; use the compiler_version recorded in dagda.lock")
        return "", false
    }
    return compiler, true
}
prepare_native :: proc(root: string) -> bool {
    if !ensure_directory(path(root, "build")) || !ensure_directory(path(root, "vendor/dagda/build")) {
        problem("Cannot create build directories (symlinks are not accepted)")
        return false
    }
    object := path(root, "vendor/dagda/build/platform.o")
    if exists(object) && !regular(object) { problem("Native output is not a regular file"); return false }
    code, _ := child({"cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-c", "vendor/dagda/native/platform.c", "-o", "vendor/dagda/build/platform.o"}, root)
    return code == 0
}
build_project :: proc(root: string, project: ^Project, lock: ^Lock, compiler: string, release := false, test := false, quiet := false) -> int {
    if !prepare_native(root) { return 1 }
    command := "test" if test else "build"
    output := "build/app-tests" if test else path("build", project.name)
    if exists(path(root, output)) && !regular(path(root, output)) { return problem("Build output is not a regular file") }
    mode := "-o:speed" if release else "-debug"
    code, _ := child({compiler, command, "app", fmt.tprintf("-out:%s", output), mode}, root, quiet)
    if code != 0 { return code }
    if !test {
        info := struct {app, framework_revision, framework_source_sha256, compiler, mode: string}{
            project.name, lock.framework_revision, lock.framework_source_sha256, lock.compiler.compiler_version,
            "release" if release else "debug",
        }
        if !write_json(path(root, "build/build-info.json"), info) { return problem("Cannot write build metadata") }
        fmt.println("Built", output)
    }
    return 0
}
DOCTOR_SOURCE :: `#include <stdio.h>
extern int PQlibVersion(void);
extern void *PQcancelCreate(void *);
int main(void) {
    void *(*volatile required)(void *) = PQcancelCreate;
    int version = PQlibVersion();
    if (version < 170000 || !required) return 1;
    printf("libpq: %d (17+ required)\n", version);
    return 0;
}
`
doctor :: proc(root: string, project: ^Project, lock: ^Lock, compiler: string, database: bool) -> int {
    fmt.println("Framework checksums: OK")
    fmt.println("Odin:", lock.compiler.compiler_version)
    if !ensure_directory(path(root, "build")) { return problem("Cannot create build directory") }
    stage, stage_error := os.make_directory_temp(path(root, "build"), "doctor-", context.allocator)
    if stage_error != nil { return problem("Cannot create doctor workspace") }
    defer os.remove_all(stage)
    source, binary := path(stage, "check.c"), path(stage, "check")
    if !write_new(source, DOCTOR_SOURCE) { return problem("Cannot write native dependency probe") }
    code, _ := child({"cc", source, "-lpq", "-o", binary}, root)
    if code != 0 { return problem("C compiler or libpq development library unavailable (17+ required)") }
    code, _ = child({binary}, root)
    if code != 0 { return problem("libpq 17 or newer is required") }
    if os.get_env("DAGDA_DATABASE_URL", context.allocator) == "" {
        if database { return problem("Set DAGDA_DATABASE_URL before checking database connectivity") }
        fmt.println("Configuration: not checked (set DAGDA_DATABASE_URL); database connectivity not requested")
        return 0
    }
    if !prepare_native(root) { return 1 }
    checker := path(stage, "app-check")
    // Odin rejects spaces in -out paths; the working directory may contain them.
    output := path("build", os.base(stage), "app-check")
    code, _ = child({compiler, "build", "app", fmt.tprintf("-out:%s", output), "-debug"}, root)
    if code != 0 { return code }
    command := []string{checker, "check"}
    if database { command = []string{command[0], "check", "--database"} }
    code, _ = child(command, root)
    return code
}
run :: proc(args: []string) -> int {
    when ODIN_OS != .Linux || ODIN_ARCH != .amd64 { return problem("This CLI currently supports Linux x86_64 only") }
    if len(args) == 0 || (len(args) == 1 && (args[0] == "--help" || args[0] == "help")) { help(); return 0 }
    if len(args) == 1 && args[0] == "--version" {
        bundle := load_bundle()
        fmt.println("dagda", VERSION, "framework", bundle.revision, "snapshot", bundle.source_id)
        return 0
    }
    root, error := os.get_working_directory(context.allocator)
    if error != nil { return problem("Cannot read current directory") }
    if args[0] == "new" {
        if len(args) < 2 || len(args) > 3 || (len(args) == 3 && args[2] != "--dry-run") { help(); return 2 }
        bundle := load_bundle()
        return create_project(&bundle, root, args[1], len(args) == 3)
    }
    if args[0] != "build" && args[0] != "test" && args[0] != "doctor" { help(); return 2 }
    if len(args) > 2 || (len(args) == 2 && !((args[0] == "build" && args[1] == "--release") || (args[0] == "doctor" && args[1] == "--database"))) { help(); return 2 }
    project, lock, ok := load_project(root)
    if !ok { return 1 }
    compiler, compiler_ok := check_compiler(root, &lock)
    if !compiler_ok { return 1 }
    switch args[0] {
    case "build": return build_project(root, &project, &lock, compiler, release=len(args) == 2)
    case "test": return build_project(root, &project, &lock, compiler, test=true)
    case "doctor": return doctor(root, &project, &lock, compiler, len(args) == 2)
    }
    return 2
}
