#ifndef SENZA_CONFIG_LOADER_H
#define SENZA_CONFIG_LOADER_H

#include "mapper_core.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Loads flattened key=value runtime profile exported by senza/profiles.py. */
bool psr_config_load_file(const char *path, PsrConfig *cfg);

#ifdef __cplusplus
}
#endif

#endif /* SENZA_CONFIG_LOADER_H */
