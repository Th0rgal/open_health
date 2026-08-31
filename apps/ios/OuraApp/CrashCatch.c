#include "CrashCatch.h"
#include <execinfo.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

static int g_fd = -1;

static void crashcatch_handler(int sig) {
    int fd = g_fd;
    if (fd >= 0) {
        static const char hdr[] = "\n*** CRASH ***\n";
        (void)write(fd, hdr, sizeof hdr - 1);
        char nbuf[] = "signal=00\n";
        nbuf[7] = (char)('0' + (sig / 10) % 10);
        nbuf[8] = (char)('0' + (sig % 10));
        (void)write(fd, nbuf, sizeof nbuf - 1);
        void *frames[48];
        int n = backtrace(frames, 48);
        backtrace_symbols_fd(frames, n, fd);
        (void)fsync(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

void crashcatch_install(int fd) {
    g_fd = fd;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = crashcatch_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND;
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
}
