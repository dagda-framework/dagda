#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <time.h>

static volatile sig_atomic_t stop_requested;

static void request_stop(int signo) {
    (void)signo;
    stop_requested = 1;
}

int dagda_install_signals(void) {
    stop_requested = 0;
    struct sigaction action = {0};
    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL)) return -1;
    action.sa_handler = SIG_IGN;
    return sigaction(SIGPIPE, &action, NULL);
}

int dagda_stop_requested(void) { return stop_requested != 0; }

int64_t dagda_monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

/* A bounded wait. EINTR returns to Odin so it can recheck its deadline. */
int dagda_wait_socket(int fd, int writing, int timeout_ms) {
    struct pollfd p = {.fd = fd, .events = writing ? POLLOUT : POLLIN};
    int result = poll(&p, 1, timeout_ms);
    if (result < 0) return errno == EINTR ? 0 : -1;
    if (result == 0) return 0;
    if (p.revents & (POLLERR | POLLNVAL)) return -1;
    return 1; /* HUP is consumed by libpq, which reports the connection error. */
}
