/* Force-included when building upstream uxn2 for Windows (MinGW, both
   zig cc in scripts/build-uxn2-windows.sh and CI's MSYS2 gcc):
   the File device uses POSIX calls MinGW spells differently. The
   system headers come first so the macro only rewrites uxn2's calls. */
#ifdef _WIN32
#include <stdio.h>
#include <io.h>
#include <direct.h>
#include <sys/stat.h>
#define mkdir(path, mode) _mkdir(path)
#endif
