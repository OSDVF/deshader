//https://github.com/search?q=SymEnumSymbols+dl_iterate_phdr&type=code
//https://github.com/cnlohr/cntools/blob/master/random/symbol_enumerator.c
#include <stdio.h>
typedef int (*SymEnumeratorCallback)(const char* path, const char* name, void* location, long size);

#if defined( WIN32 ) || defined( WINDOWS ) || defined( USE_WINDOWS ) || defined( _WIN32 )

#include <windows.h>
#include <dbghelp.h>


BOOL CALLBACK mycb(PSYMBOL_INFO pSymInfo, ULONG SymbolSize, PVOID UserContext) {
	SymEnumeratorCallback cb = (SymEnumeratorCallback)UserContext;
	return !cb("", &pSymInfo->Name[0], (void*)pSymInfo->Address, (long)pSymInfo->Size);
}

int EnumerateSymbols(SymEnumeratorCallback cb, const char* path)
{
	HANDLE proc = GetCurrentProcess();
	if (!SymInitialize(proc, 0, 1)) return -1;
	DWORD64 BaseOfDll = SymLoadModuleEx(proc,
		NULL,
		path,
		NULL,
		0,
		0,
		NULL,
		0);
	if (BaseOfDll == 0)
	{
		SymCleanup(proc);
		return -3;
	}
	if (!SymEnumSymbols(proc, 0, "*!*", &mycb, (void*)cb))
	{
		fprintf(stderr, "SymEnumSymbols returned %d\n", GetLastError());
		SymCleanup(proc);
		return -2;
	}
	SymCleanup(proc);
	return 0;
}

#else


#include <stdio.h>
#include <dlfcn.h>
#include <stdint.h>
#include <limits.h>
#include <string.h>

#ifndef __GNUC__
#define __int128_t long long long
#endif

#include <link.h>
#include <elf.h>

#define UINTS_PER_WORD (__WORDSIZE / (CHAR_BIT * sizeof (unsigned int)))


static ElfW(Word) gnu_hashtab_symbol_count(const unsigned int* const table)
{
	const unsigned int* const bucket = table + 4 + table[2] * (unsigned int)(UINTS_PER_WORD);
	unsigned int              b = table[0];
	unsigned int              max = 0U;

	while (b-- > 0U)
		if (bucket[b] > max)
			max = bucket[b];

	return (ElfW(Word))max;
}

static void* dynamic_pointer(const ElfW(Addr) addr, const ElfW(Addr) base, const ElfW(Phdr)* const header,
	const ElfW(Half) headers) {
	if (addr) {
		ElfW(Half) h;

		for (h = 0; h < headers; h++)
			if (header[h].p_type == PT_LOAD)
				if (addr >= base + header[h].p_vaddr &&
					addr < base + header[h].p_vaddr + header[h].p_memsz)
					return (void*)addr;
	}

	return NULL;
}

//Mostly based off of http://stackoverflow.com/questions/29903049/get-names-and-addresses-of-exported-functions-from-in-linux
static int callback(struct dl_phdr_info* info,
	size_t size, void* data)
{
	SymEnumeratorCallback cb = (SymEnumeratorCallback)data;
	const ElfW(Addr)                 base = info->dlpi_addr;
	const ElfW(Phdr)* const          header = info->dlpi_phdr;
	const ElfW(Half)                 headers = info->dlpi_phnum;
	const char* libpath, * libname;
	ElfW(Half)                       h;

	if (info->dlpi_name && info->dlpi_name[0])
		libpath = info->dlpi_name;
	else
		libpath = "";

	libname = strrchr(libpath, '/');

	if (libname && libname[0] == '/' && libname[1])
		libname++;
	else
		libname = libpath;

	for (h = 0; h < headers; h++)
	{
		if (header[h].p_type == PT_DYNAMIC)
		{
			const ElfW(Dyn)* entry = (const ElfW(Dyn)*)(base + header[h].p_vaddr);
			const ElfW(Word)* hashtab;
			const ElfW(Sym)* symtab = NULL;
			const char* strtab = NULL;
			ElfW(Word)        symbol_count = 0;

			for (; entry->d_tag != DT_NULL; entry++)
			{
				switch (entry->d_tag)
				{
				case DT_HASH:
					hashtab = reinterpret_cast<const ElfW(Word)*>(dynamic_pointer(entry->d_un.d_ptr, base, header, headers));
					if (hashtab)
						symbol_count = hashtab[1];
					break;
				case DT_GNU_HASH:
					hashtab = reinterpret_cast<const ElfW(Word)*>(dynamic_pointer(entry->d_un.d_ptr, base, header, headers));
					if (hashtab)
					{
						ElfW(Word) count = gnu_hashtab_symbol_count(hashtab);
						if (count > symbol_count)
							symbol_count = count;
					}
					break;
				case DT_STRTAB:
					strtab = reinterpret_cast<const char*>(dynamic_pointer(entry->d_un.d_ptr, base, header, headers));
					break;
				case DT_SYMTAB:
					symtab = reinterpret_cast<const ElfW(Sym)*>(dynamic_pointer(entry->d_un.d_ptr, base, header, headers));
					break;
				}
			}

			if (symtab && strtab && symbol_count > 0) {
				ElfW(Word)  s;

				for (s = 0; s < symbol_count; s++) {
					const char* name;
					void* const ptr = dynamic_pointer(base + symtab[s].st_value, base, header, headers);
					int         result;

					if (!ptr)
						continue;

					if (symtab[s].st_name)
						name = strtab + symtab[s].st_name;
					else
						name = "";

					result = cb(libpath, name, ptr, symtab[s].st_size);
					if (result) return result; //Bail early.
				}
			}
		}
	}
	return 0;
}

int EnumerateSymbols(SymEnumeratorCallback cb, const char* path)
{
	auto handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
	if(handle == NULL) {
		auto err = dlerror();
		fprintf(stderr, "dlopen failed: %s\n", err);
		return -1;
	}
	dl_iterate_phdr(callback, (void*)cb);
	return 0;
}

#endif

int main(int argc, const  char* argv[]) {
	// first argument is the path to the library
	if (argc <= 1) {
		fprintf(stderr, "Usage: %s <path to library>\n", argv[0]);
		return 1;
	}

	// enumerate symbols
	for(size_t i = 0; i < argc; i++) {
		EnumerateSymbols([](const char* path, const char* name, void* location, long size) {
		printf("%s %s %p %ld\n", path, name, location, size);
		return 0;
		}, argv[i]);
	}
}