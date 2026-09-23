// Public Process Manager compatibility bridge. Never resolves by bundle ID.
#include <stdint.h>
#include <stdbool.h>
typedef struct { uint32_t high; uint32_t low; } PDProcessReference;
int32_t PDResolveProcess(int32_t pid, PDProcessReference *reference);
int32_t PDActivateProcess(PDProcessReference reference, int32_t expectedPID, bool userInitiated);
