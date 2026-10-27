// rebind.c - minimal dyld image-list hiding via GOT/la_symbol_ptr rebinding.
//
// Why: ACE (anogs) walks the dyld image list to find foreign dylibs. We keep our
// own image out of that list by rebinding the dyld query functions in every
// loaded image's symbol pointer tables.
//
// This is a self-contained implementation (no external fishhook dependency):
//   - walk LC_SYMTAB + LC_DYSYMTAB of a Mach-O image
//   - for sections of type S_LAZY_SYMBOL_POINTERS / S_NON_LAZY_SYMBOL_POINTERS
//   - resolve each indirect symbol name from the string table
//   - replace the pointer for names we care about

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#define REBIND_MAX 16

// declared early: used by the index-mapping helpers below
static char g_fake_name[512];
static int  g_spoof = 1;   // 1 = keep image count, spoof our name; 0 = drop ourselves

struct rebinding {
    const char* name;
    void* replacement;
    void** replaced;
};

// ---- our own image discovery ----
static const struct mach_header_64* g_self_header = NULL;
static uint32_t g_self_index = 0;
static int      g_self_found = 0;

static void find_self(void) {
    // the image whose header contains this function's own address range:
    // simplest reliable way is to compare the header of the image that dyld
    // reports for a symbol inside ourselves.
    uint32_t n = _dyld_image_count();
    const void* anchor = (const void*)&find_self;
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header* h = _dyld_get_image_header(i);
        if (!h) continue;
        const uint8_t* base = (const uint8_t*)h;
        // our function lives inside some __TEXT; check coarse range using segment 0 size
        const struct mach_header_64* mh = (const struct mach_header_64*)h;
        if (mh->magic != MH_MAGIC_64) continue;
        const struct load_command* lc = (const struct load_command*)(base + sizeof(*mh));
        uint64_t vmaddr = 0, vmsize = 0;
        for (uint32_t k = 0; k < mh->ncmds; k++) {
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64* s = (const struct segment_command_64*)lc;
                if (strcmp(s->segname, "__TEXT") == 0) { vmaddr = s->vmaddr; vmsize = s->vmsize; break; }
            }
            lc = (const struct load_command*)((const uint8_t*)lc + lc->cmdsize);
        }
        if (vmsize == 0) continue;   // dylibs report __TEXT vmaddr == 0 - do not skip them
        // vmaddr is a LINK-TIME address: subtract the slide before comparing,
        // otherwise our own image is never matched (this bug shipped once).
        intptr_t sl = _dyld_get_image_vmaddr_slide(i);
        uint64_t addr = (uint64_t)anchor - (uint64_t)sl;
        if (addr >= vmaddr && addr < vmaddr + vmsize) {
            g_self_header = mh;
            g_self_index = i;
            g_self_found = 1;
            return;
        }
    }
}

// ---- rebinding inside one image ----
static int rebind_in_image(const struct mach_header_64* mh, intptr_t slide,
                           struct rebinding* binds, int nbinds) {
    const uint8_t* base = (const uint8_t*)mh;
    const struct symtab_command* symtab = NULL;
    const struct dysymtab_command* dysym = NULL;
    const struct segment_command_64* linkedit = NULL;

    const struct load_command* lc = (const struct load_command*)(base + sizeof(*mh));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command*)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysym = (const struct dysymtab_command*)lc;
        else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* s = (const struct segment_command_64*)lc;
            if (strcmp(s->segname, "__LINKEDIT") == 0) linkedit = s;
        }
        lc = (const struct load_command*)((const uint8_t*)lc + lc->cmdsize);
    }
    if (!symtab || !dysym || !linkedit) return 0;

    const struct nlist_64* syms = (const struct nlist_64*)(base + symtab->symoff);
    const char* strs = (const char*)(base + symtab->stroff);
    const uint32_t* indirect = (const uint32_t*)(base + dysym->indirectsymoff);
    int patched = 0;

    lc = (const struct load_command*)(base + sizeof(*mh));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* seg = (const struct segment_command_64*)lc;
            const struct section_64* sect = (const struct section_64*)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
                uint32_t type = sect->flags & SECTION_TYPE;
                if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
                uint32_t count = (uint32_t)(sect->size / sizeof(void*));
                void** slots = (void**)(base + sect->offset);
                // __got often lives in __DATA_CONST (read-only after fixups). Writing
                // there without mprotect is an instant crash at launch.
                {
                    uintptr_t pg = (uintptr_t)slots & ~(uintptr_t)(getpagesize() - 1);
                    size_t len = ((uintptr_t)slots + sect->size) - pg;
                    if (mprotect((void*)pg, len, PROT_READ | PROT_WRITE) != 0) {
                        continue;   // cannot make it writable: skip this section
                    }
                }
                for (uint32_t k = 0; k < count; k++) {
                    uint32_t symIdx = indirect[sect->reserved1 + k];
                    if (symIdx == INDIRECT_SYMBOL_ABS || symIdx == INDIRECT_SYMBOL_LOCAL) continue;
                    if (symIdx >= symtab->nsyms) continue;
                    const struct nlist_64* nl = &syms[symIdx];
                    if (nl->n_un.n_strx >= symtab->strsize) continue;
                    const char* nm = strs + nl->n_un.n_strx;
                    for (int b = 0; b < nbinds; b++) {
                        if (strcmp(nm, binds[b].name) != 0) continue;
                        if (slots[k] == binds[b].replacement) break;      // already patched
                        if (binds[b].replaced && *binds[b].replaced == NULL) *binds[b].replaced = slots[k];
                        slots[k] = binds[b].replacement;
                        patched++;
                        break;
                    }
                }
            }
        }
        lc = (const struct load_command*)((const uint8_t*)lc + lc->cmdsize);
    }
    return patched;
}

// ---- filtered dyld API (what the scanners will see) ----
static uint32_t (*orig_image_count)(void) = NULL;
static const struct mach_header* (*orig_get_header)(uint32_t) = NULL;
static const char* (*orig_get_name)(uint32_t) = NULL;
static intptr_t (*orig_get_slide)(uint32_t) = NULL;

// map a filtered index to the real index, skipping our own image
static uint32_t real_index(uint32_t i) {
    if (!g_self_found || g_spoof) return i;
    return (i >= g_self_index) ? (i + 1) : i;
}

static uint32_t my_image_count(void) {
    uint32_t n = orig_image_count ? orig_image_count() : 0;
    if (!g_spoof && g_self_found && n > 0) n -= 1;
    return n;
}
static const struct mach_header* my_get_header(uint32_t i) {
    if (!orig_get_header) return NULL;
    uint32_t n = orig_image_count ? orig_image_count() : 0;
    uint32_t r = real_index(i);
    if (r >= n) return NULL;
    return orig_get_header(r);
}
static const char* my_get_name(uint32_t i) {
    if (!orig_get_name) return NULL;
    uint32_t n = orig_image_count ? orig_image_count() : 0;
    if (g_spoof) {
        if (g_self_found && i == g_self_index && g_fake_name[0]) return g_fake_name;
        if (i >= n) return NULL;
        return orig_get_name(i);
    }
    uint32_t r = real_index(i);
    if (r >= n) return NULL;
    return orig_get_name(r);
}
static intptr_t my_get_slide(uint32_t i) {
    if (!orig_get_slide) return 0;
    uint32_t n = orig_image_count ? orig_image_count() : 0;
    uint32_t r = real_index(i);
    if (r >= n) return 0;
    return orig_get_slide(r);
}

// ---- public entry ----
int hide_self_image(int spoofMode, const char* fakeName) {
    g_spoof = spoofMode ? 1 : 0;
    find_self();
    if (!g_self_found) return -1;

    // choose a boring, whitelisted-looking name so a per-image whitelist check passes
    g_fake_name[0] = 0;
    if (g_spoof) {
        if (fakeName && fakeName[0]) {
            strncpy(g_fake_name, fakeName, sizeof(g_fake_name) - 1);
        } else {
            const char* n0 = _dyld_get_image_name(0);   // the game executable
            if (n0) strncpy(g_fake_name, n0, sizeof(g_fake_name) - 1);
        }
    }

    struct rebinding binds[4];
    memset(binds, 0, sizeof(binds));
    binds[0].name = "_dyld_image_count";       binds[0].replacement = (void*)my_image_count;
    binds[0].replaced = (void**)&orig_image_count;
    binds[1].name = "_dyld_get_image_header";  binds[1].replacement = (void*)my_get_header;
    binds[1].replaced = (void**)&orig_get_header;
    binds[2].name = "_dyld_get_image_name";    binds[2].replacement = (void*)my_get_name;
    binds[2].replaced = (void**)&orig_get_name;
    binds[3].name = "_dyld_get_image_vmaddr_slide"; binds[3].replacement = (void*)my_get_slide;
    binds[3].replaced = (void**)&orig_get_slide;

    int total = 0;
    for (int pass = 0; pass < 2; pass++) {
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const struct mach_header* h = _dyld_get_image_header(i);
            if (!h || h->magic != MH_MAGIC_64) continue;
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            total += rebind_in_image((const struct mach_header_64*)h, slide, binds, 4);
        }
        // second pass catches images that were lazily bound in between
    }
    return total;
}
