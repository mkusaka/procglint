#ifndef CPROCGLINT_DARWIN_H
#define CPROCGLINT_DARWIN_H

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <sys/resource.h>
#include <sys/sysctl.h>

// POSIX wrappers return an errno value (zero on success); Mach wrappers return kern_return_t.
int pg_list_pids(int32_t *buffer, int capacity, int *count);
int pg_rusage(int32_t pid, struct rusage_info_v2 *usage);

typedef struct {
    char name[64];
    uint32_t uid;
    int32_t ppid;
    uint64_t start_time_us;
    int has_start_time;
} pg_bsd_info;

int pg_bsd(int32_t pid, pg_bsd_info *info);

typedef struct {
    void *storage;
    size_t capacity;
} pg_census_buffer;

typedef struct {
    int32_t pid;
    pg_bsd_info bsd;
} pg_census_entry;

int pg_census(pg_census_buffer *buffer, int *count);
// Returns zero for zombies, one for a live entry.
int pg_census_get(const pg_census_buffer *buffer, int index, pg_census_entry *entry);
void pg_census_free(pg_census_buffer *buffer);

int pg_path(int32_t pid, char *buffer, uint32_t capacity);

typedef struct {
    uint32_t user, system, idle, nice;
} pg_cpu_ticks;

typedef struct {
    uint64_t active, inactive, wired, compressor, free;
} pg_vm_statistics;

kern_return_t pg_host_cpu(pg_cpu_ticks *ticks);
kern_return_t pg_host_vm(pg_vm_statistics *statistics);
kern_return_t pg_timebase(mach_timebase_info_t info);
kern_return_t pg_page_size(vm_size_t *size);
int pg_boot_session(char *buffer, size_t *size);
int pg_physical_memory(uint64_t *size);
int pg_memory_pressure(int32_t *level);
int pg_swap_usage(struct xsw_usage *usage);

#endif
