// inprobe/bootlog.h - boot-level logging + crash signal capture.
//
// Purpose: when the injected dylib dies before any UI exists, we still need to
// know exactly which statement killed the process. This writes to the first
// writable path it finds, flushes immediately, and installs signal handlers that
// record the fault before letting the process die.
//
// Paths tried in order:
//   <container>/Documents/boot.log      (always writable for the app itself)
//   /var/mobile/Library/Preferences/aresp_boot.log   (jailbroken sandbox)
//   /tmp/aresp_boot.log
//   /var/tmp/aresp_boot.log

#pragma once
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <pthread.h>

static char  g_bootPath[1024];
static int   g_bootReady = 0;
static int   g_crashCount = 0;

static void bootlog_raw(const char* s) {
    if (!g_bootReady) {
        // resolve the path once
        const char* cands[4];
        char c0[1024];
        c0[0] = 0;
        // Documents of the host app (we are injected into it)
        const char* home = getenv("HOME");
        if (home && home[0]) {
            snprintf(c0, sizeof(c0), "%s/Documents/boot.log", home);
            cands[0] = c0;
        } else {
            cands[0] = NULL;
        }
        cands[1] = "/var/mobile/Library/Preferences/aresp_boot.log";
        cands[2] = "/tmp/aresp_boot.log";
        cands[3] = "/var/tmp/aresp_boot.log";

        for (int i = 0; i < 4; i++) {
            if (!cands[i]) continue;
            FILE* fp = fopen(cands[i], "a");
            if (fp) { fclose(fp); strncpy(g_bootPath, cands[i], sizeof(g_bootPath) - 1); break; }
        }
        g_bootReady = g_bootPath[0] != 0;
        if (!g_bootReady) return;
    }
    FILE* fp = fopen(g_bootPath, "a");
    if (!fp) return;
    fprintf(fp, "%s\n", s);
    fclose(fp);          // close every line: survives immediate death
}

static void bootlog(const char* fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    bootlog_raw(buf);
}

// ---- crash capture ----
static struct sigaction g_oldSEGV, g_oldBUS, g_oldABRT, g_oldILL, g_oldSYS, g_oldFPE, g_oldTRAP;

static void crash_handler(int sig, siginfo_t* si, void* uc) {
    // keep the handler async-signal-safe: no ObjC, no malloc
    char buf[256];
    int off = 0;
    off += snprintf(buf + off, sizeof(buf) - off, "[CRASH] sig=%d (%s) addr=%p",
                    sig,
                    sig == SIGSEGV ? "SIGSEGV" : sig == SIGBUS ? "SIGBUS" :
                    sig == SIGABRT ? "SIGABRT" : sig == SIGILL ? "SIGILL" :
                    sig == SIGSYS ? "SIGSYS" : sig == SIGFPE ? "SIGFPE" :
                    sig == SIGTRAP ? "SIGTRAP" : "?",
                    si ? si->si_addr : 0);
    g_crashCount++;
    if (g_crashCount > 3) _exit(9);      // avoid loops
    if (g_bootReady) {
        FILE* fp = fopen(g_bootPath, "a");
        if (fp) { fprintf(fp, "%s\n", buf); fclose(fp); }
    }
    // fall through to the previous handler / default action
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_crash_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &g_oldSEGV);
    sigaction(SIGBUS,  &sa, &g_oldBUS);
    sigaction(SIGABRT, &sa, &g_oldABRT);
    sigaction(SIGILL,  &sa, &g_oldILL);
    sigaction(SIGSYS,  &sa, &g_oldSYS);     // the commercial cheat dies here
    sigaction(SIGFPE,  &sa, &g_oldFPE);
    sigaction(SIGTRAP, &sa, &g_oldTRAP);
    bootlog("[boot] crash handlers installed");
}
