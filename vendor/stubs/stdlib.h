#pragma once
#include "stddef.h"
void *malloc(size_t size);
void *calloc(size_t n, size_t size);
void *realloc(void *ptr, size_t size);
void  free(void *ptr);
void  abort(void) __attribute__((noreturn));
void  exit(int code) __attribute__((noreturn));
