// LD_PRELOAD probe for spike #32: log every __cxa_atexit and on_exit
// registration with its thread and the library of the function registered.
#include <dlfcn.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cstdio>

namespace {
void log_registration(const char* what, void* fn) {
  Dl_info info{};
  dladdr(fn, &info);
  char text[512];
  const int n = std::snprintf(
      text, sizeof text, "[cxatrace %s tid=%ld main=%d %s %s]\n", what,
      static_cast<long>(syscall(SYS_gettid)),
      syscall(SYS_gettid) == getpid() ? 1 : 0,
      info.dli_fname != nullptr ? info.dli_fname : "?",
      info.dli_sname != nullptr ? info.dli_sname : "?");
  if (n > 0) {
    [[maybe_unused]] const ssize_t w = write(2, text, static_cast<size_t>(n));
  }
}
}  // namespace

extern "C" {
int __cxa_atexit(void (*fn)(void*), void* arg, void* dso) {
  using real_t = int (*)(void (*)(void*), void*, void*);
  static auto real = reinterpret_cast<real_t>(dlsym(RTLD_NEXT, "__cxa_atexit"));
  log_registration("__cxa_atexit", reinterpret_cast<void*>(fn));
  return real(fn, arg, dso);
}

int on_exit(void (*fn)(int, void*), void* arg) {
  using real_t = int (*)(void (*)(int, void*), void*);
  static auto real = reinterpret_cast<real_t>(dlsym(RTLD_NEXT, "on_exit"));
  log_registration("on_exit", reinterpret_cast<void*>(fn));
  return real(fn, arg);
}
}
