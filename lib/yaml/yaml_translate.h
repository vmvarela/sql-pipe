/*
 * Wrapper header for Zig translateC that avoids the MSVC secure CRT trap.
 *
 * yaml.h includes <string.h> which on MSVC pulls in <wchar.h> declaring
 * wcscat_s/wcscpy_s. Zig 0.16's translateC generates bindings for all
 * declarations, but libyaml never calls these, causing "unused local
 * constant" errors.
 *
 * Pre-define _INC_STRING to skip <string.h> (we provide size_t via <stddef.h>).
 * The C compilation step uses the real yaml.h with string.h intact.
 */

#ifndef YAML_TRANSLATE_H
#define YAML_TRANSLATE_H

#include <stddef.h>

#define _INC_STRING 1

#include "yaml.h"

#endif /* YAML_TRANSLATE_H */