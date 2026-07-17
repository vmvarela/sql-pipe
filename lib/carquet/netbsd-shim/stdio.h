/* Minimal stdio.h shim for NetBSD cross-compilation with Zig.
 *
 * Zig's bundled NetBSD libc headers use GCC-specific extensions
 * (__attribute__((visibility)), __pragma) that Zig's @cImport C translator
 * cannot parse. carquet only needs an opaque FILE type and a handful of
 * stdio function declarations, so we provide a minimal stand-in that
 * shadows the broken system header on NetBSD targets.
 *
 * This file is only added to the include path for NetBSD in build.zig.
 */
#ifndef CARQUET_NETBSD_STDIO_SHIM
#define CARQUET_NETBSD_STDIO_SHIM

#include <stddef.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque-but-sized FILE stand-in. carquet only passes FILE* around; the
 * real layout lives in NetBSD libc and is not needed at compile time. */
typedef struct _IO_FILE {
    unsigned char _opaque[128];
} FILE;

/* NetBSD libc provides __sF[3]; stdin/stdout/stderr are macros into it. */
extern FILE __sF[3];
#define stdin  (&__sF[0])
#define stdout (&__sF[1])
#define stderr (&__sF[2])

FILE *fopen(const char *path, const char *mode);
int fclose(FILE *stream);
int fflush(FILE *stream);
int fprintf(FILE *stream, const char *format, ...);
int printf(const char *format, ...);
int fputc(int c, FILE *stream);
int fputs(const char *s, FILE *stream);
size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
int fseek(FILE *stream, long offset, int whence);
long ftell(FILE *stream);
void rewind(FILE *stream);
int fgetc(FILE *stream);
char *fgets(char *s, int size, FILE *stream);
int ferror(FILE *stream);
int feof(FILE *stream);
int remove(const char *path);
FILE *tmpfile(void);
int fileno(FILE *stream);
int sscanf(const char *str, const char *format, ...);
int snprintf(char *str, size_t size, const char *format, ...);
int vsnprintf(char *str, size_t size, const char *format, va_list ap);
int vfprintf(FILE *stream, const char *format, va_list ap);

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define EOF (-1)
#define FILENAME_MAX 1024
#define BUFSIZ 1024
#define L_tmpnam 1024
#define TMP_MAX 308915776

#ifdef __cplusplus
}
#endif

#endif /* CARQUET_NETBSD_STDIO_SHIM */
