#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

typedef const int32_t* (*abi_fn)(void);

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: abi-probe LIBRARY\n");
    return 2;
  }
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (library == NULL) {
    fprintf(stderr, "dlopen: %s\n", dlerror());
    return 1;
  }
  void* symbol = dlsym(library, "rr_abi");
  if (symbol == NULL) {
    fprintf(stderr, "no rr_abi export\n");
    return 1;
  }
  abi_fn abi = NULL;
  *(void**)&abi = symbol;
  const int32_t* tag = abi();
  if (tag == NULL) {
    fprintf(stderr, "rr_abi returned NULL\n");
    return 1;
  }
  printf("%d\n", (int)tag[0]);
  return 0;
}
