/* uxn2-embed.c: single-file game launcher around upstream uxn2.

   Built together with uxn2.c, whose `main` is renamed to `uxn2_main`
   (-Dmain=uxn2_main -DSDL_MAIN_HANDLED on that file only), so upstream
   stays untouched. `etal --target windows-x86_64` writes

       [this VM][game.rom][footer]

   as one .exe (and, for the unix rows, as one ELF / Mach-O). The
   footer is the last 16 bytes:

       "ETALROM1"  magic (8 bytes)
       u32 LE      ROM length
       u8          flags: 1 = fullscreen (-f), 2 = 2x window (-2)
       3 bytes     zero

   With a footer, the ROM is written to a temp file and run with the
   baked flags, then any arguments the player passed. Without one
   this is plain uxn2 (`uxn2 [-f -2] file.rom`), which is how the
   compiler assembles ROMs on a Windows host. */
#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <process.h>
#define getpid _getpid
#else
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#endif

int uxn2_main(int argc, char **argv);

#define FOOTER 16
#define MAX_ROM 0x10000

static char rom_path[4096];

static void
drop_rom(void)
{
	if(rom_path[0]) remove(rom_path);
}

static int
self_path(char *buf, size_t n)
{
#ifdef _WIN32
	DWORD r = GetModuleFileNameA(NULL, buf, (DWORD)n);
	return r > 0 && r < n;
#elif defined(__APPLE__)
	uint32_t size = (uint32_t)n;
	return _NSGetExecutablePath(buf, &size) == 0;
#else
	ssize_t r = readlink("/proc/self/exe", buf, n - 1);
	if(r <= 0) return 0;
	buf[r] = '\0';
	return 1;
#endif
}

static int
temp_rom(char *buf, size_t n)
{
#ifdef _WIN32
	char dir[MAX_PATH];
	DWORD r = GetTempPathA(sizeof dir, dir);
	if(r == 0 || r >= sizeof dir) return 0;
	return snprintf(buf, n, "%setal-%d.rom", dir, (int)getpid()) < (int)n;
#else
	const char *dir = getenv("TMPDIR");
	return snprintf(buf, n, "%s/etal-%d.rom", dir ? dir : "/tmp", (int)getpid()) < (int)n;
#endif
}

/* The embedded ROM, or 0 (no footer: behave as plain uxn2). */
static unsigned char *
embedded(unsigned long *len, int *flags)
{
	char self[4096];
	unsigned char foot[FOOTER], *rom;
	long size;
	FILE *f;
	if(!self_path(self, sizeof self) || !(f = fopen(self, "rb"))) return 0;
	if(fseek(f, 0, SEEK_END) || (size = ftell(f)) < FOOTER || fseek(f, size - FOOTER, SEEK_SET) || fread(foot, 1, FOOTER, f) != FOOTER || memcmp(foot, "ETALROM1", 8)) {
		fclose(f);
		return 0;
	}
	*len = foot[8] | foot[9] << 8 | (unsigned long)foot[10] << 16 | (unsigned long)foot[11] << 24;
	*flags = foot[12];
	if(*len == 0 || *len > MAX_ROM || (long)*len > size - FOOTER || !(rom = malloc(*len))) {
		fclose(f);
		return 0;
	}
	if(fseek(f, size - FOOTER - (long)*len, SEEK_SET) || fread(rom, 1, *len, f) != *len) {
		free(rom);
		fclose(f);
		return 0;
	}
	fclose(f);
	return rom;
}

int
main(int argc, char **argv)
{
	unsigned long len = 0;
	int flags = 0, n = 0, i, rc;
	unsigned char *rom = embedded(&len, &flags);
	char **args;
	FILE *out;
	SDL_SetMainReady();
	if(!rom) return uxn2_main(argc, argv);
	if(!temp_rom(rom_path, sizeof rom_path) || !(out = fopen(rom_path, "wb"))) {
		fprintf(stderr, "%s: cannot write a temporary file for the game\n", argv[0]);
		return 1;
	}
	if(fwrite(rom, 1, len, out) != len) {
		fclose(out);
		drop_rom();
		return 1;
	}
	fclose(out);
	free(rom);
	atexit(drop_rom);
	args = calloc((size_t)argc + 4, sizeof *args);
	if(!args) return 1;
	args[n++] = argv[0];
	if(flags & 1) args[n++] = "-f";
	if(flags & 2) args[n++] = "-2";
	args[n++] = rom_path;
	for(i = 1; i < argc; i++) args[n++] = argv[i];
	rc = uxn2_main(n, args);
	drop_rom();
	return rc;
}
