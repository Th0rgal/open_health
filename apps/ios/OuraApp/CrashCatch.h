#ifndef OURA_CRASH_CATCH_H
#define OURA_CRASH_CATCH_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
/// Install SIGABRT/SEGV/BUS/ILL/TRAP handlers that write a backtrace to `fd`
/// (kept open for the process lifetime) then re-raise the signal. Call once
/// at launch after opening the current session log.
void crashcatch_install(int fd);
#ifdef __cplusplus
}
#endif
#endif
