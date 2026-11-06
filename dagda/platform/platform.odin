package dagda_platform

foreign import shim "../../build/platform.o"

foreign shim {
    @(link_name="dagda_install_signals")
    install_signals :: proc() -> i32 ---
    @(link_name="dagda_stop_requested")
    stop_requested :: proc() -> i32 ---
    @(link_name="dagda_monotonic_ms")
    monotonic_ms :: proc() -> i64 ---
    @(link_name="dagda_wait_socket")
    wait_socket :: proc(fd: i32, writing: i32, timeout_ms: i32) -> i32 ---
}
