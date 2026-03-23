#pragma once
#include "stddef.h"
#include "stdarg.h"
typedef struct _FILE FILE;
extern FILE *stderr;
extern FILE *stdout;
int fprintf(FILE *f, const char *fmt, ...);
int printf(const char *fmt, ...);
int snprintf(char *buf, size_t n, const char *fmt, ...);
int sprintf(char *buf, const char *fmt, ...);
int vsnprintf(char *buf, size_t n, const char *fmt, __builtin_va_list ap);
