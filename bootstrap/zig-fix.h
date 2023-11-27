#ifndef _ZIG_H_FIX
#define _ZIG_H_FIX
#include "${REAL_ZIG_H}"
#ifdef __GNUC__ // GCC does not support tail recursion attributes but Zig does not detect that correctly
#ifndef __clang__
#define zig_always_tail
#define zig_never_tail
#endif
#endif
#endif