#ifndef DUALMAC_CONFIG_LOADER_H
#define DUALMAC_CONFIG_LOADER_H

#include "mapper_core.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Loads flattened key=value runtime profile exported by dualmac/profiles.py. */
bool psr_config_load_file(const char *path, PsrConfig *cfg);

#ifdef __cplusplus
}
#endif

#endif /* DUALMAC_CONFIG_LOADER_H */
