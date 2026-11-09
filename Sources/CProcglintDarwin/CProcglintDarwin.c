#include "CProcglintDarwin.h"
#include <errno.h>
#include <limits.h>
#include <libproc.h>
#include <string.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <sys/proc.h>

int pg_list_pids(int32_t *buffer, int capacity, int *count) {
    if (capacity < 0 || capacity > INT_MAX / (int)sizeof(int32_t)) return EINVAL;
    errno = 0;
    int result = proc_listallpids(buffer, capacity * (int)sizeof(int32_t));
    if (result <= 0) return errno ? errno : EIO;
    *count = result;
    return 0;
}

int pg_census(pg_census_buffer *buffer, int *count) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    for (int attempt = 0; attempt <= 4; ++attempt) {
        if (!buffer->storage) {
            size_t needed = 0;
            if (sysctl(mib, 4, NULL, &needed, NULL, 0) != 0) return errno;
            if (needed > (SIZE_MAX - sizeof(struct kinfo_proc)) / 5 * 4) return ENOMEM;
            needed += needed / 4 + sizeof(struct kinfo_proc);
            buffer->storage = malloc(needed);
            if (!buffer->storage) return ENOMEM;
            buffer->capacity = needed;
        }
        size_t size = buffer->capacity;
        if (sysctl(mib, 4, buffer->storage, &size, NULL, 0) == 0) {
            if (size == 0 || size % sizeof(struct kinfo_proc) != 0 || size / sizeof(struct kinfo_proc) > INT_MAX) return EIO;
            *count = (int)(size / sizeof(struct kinfo_proc));
            return 0;
        }
        if (errno != ENOMEM) return errno;
        // Population growth invalidates the size estimate, not the whole sweep.
        pg_census_free(buffer);
    }
    return ENOMEM;
}

int pg_census_get(const pg_census_buffer *buffer, int index, pg_census_entry *entry) {
    const struct kinfo_proc *process = &((const struct kinfo_proc *)buffer->storage)[index];
    if (process->kp_proc.p_stat == SZOMB) return 0;
    memset(entry, 0, sizeof(*entry));
    entry->pid = process->kp_proc.p_pid;
    memcpy(entry->bsd.name, process->kp_proc.p_comm, sizeof(process->kp_proc.p_comm));
    entry->bsd.uid = process->kp_eproc.e_ucred.cr_uid;
    entry->bsd.ppid = process->kp_eproc.e_ppid;
    struct timeval start = process->kp_proc.p_starttime;
    entry->bsd.start_time_us = (uint64_t)start.tv_sec * 1000000 + start.tv_usec;
    entry->bsd.has_start_time = 1;
    return 1;
}

void pg_census_free(pg_census_buffer *buffer) {
    free(buffer->storage);
    buffer->storage = NULL;
    buffer->capacity = 0;
}

int pg_rusage(int32_t pid, int flavor, struct rusage_info_v6 *usage) {
    errno = 0;
    if (proc_pid_rusage(pid, flavor, (rusage_info_t *)usage) != 0)
        return errno ? errno : EIO;
    return 0;
}

int pg_bsd(int32_t pid, pg_bsd_info *info) {
    struct proc_bsdinfo full = {0};
    memset(info, 0, sizeof(*info));
    errno = 0;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &full, sizeof(full));
    if (size == sizeof(full)) {
        const char *name = full.pbi_name[0] ? full.pbi_name : full.pbi_comm;
        size_t capacity = full.pbi_name[0] ? sizeof(full.pbi_name) : sizeof(full.pbi_comm);
        memcpy(info->name, name, strnlen(name, capacity));
        info->uid = full.pbi_uid;
        info->ppid = (int32_t)full.pbi_ppid;
        info->start_time_us = full.pbi_start_tvsec * 1000000 + full.pbi_start_tvusec;
        info->has_start_time = 1;
        return 0;
    }
    int error = errno ? errno : EIO;
    if (error != EPERM && error != EACCES) return error;

    struct proc_bsdshortinfo short_info = {0};
    errno = 0;
    size = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short_info, sizeof(short_info));
    if (size != sizeof(short_info)) return errno ? errno : EIO;
    memcpy(info->name, short_info.pbsi_comm, sizeof(short_info.pbsi_comm));
    info->uid = short_info.pbsi_uid;
    info->ppid = (int32_t)short_info.pbsi_ppid;
    return 0;
}

int pg_path(int32_t pid, char *buffer, uint32_t capacity) {
    errno = 0;
    if (proc_pidpath(pid, buffer, capacity) <= 0) return errno ? errno : EIO;
    return 0;
}

int pg_cwd(int32_t pid, char *buffer, uint32_t capacity) {
    struct proc_vnodepathinfo info = {0};
    errno = 0;
    int size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (size != sizeof(info)) return errno ? errno : EIO;
    size_t length = strnlen(info.pvi_cdir.vip_path, sizeof(info.pvi_cdir.vip_path));
    if (length == 0 || length >= sizeof(info.pvi_cdir.vip_path) || length >= capacity) return EINVAL;
    memcpy(buffer, info.pvi_cdir.vip_path, length + 1);
    return 0;
}

kern_return_t pg_host_cpu(pg_cpu_ticks *ticks) {
    host_cpu_load_info_data_t info = {0};
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    host_t host = mach_host_self();
    kern_return_t result = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result == KERN_SUCCESS) {
        ticks->user = info.cpu_ticks[CPU_STATE_USER];
        ticks->system = info.cpu_ticks[CPU_STATE_SYSTEM];
        ticks->idle = info.cpu_ticks[CPU_STATE_IDLE];
        ticks->nice = info.cpu_ticks[CPU_STATE_NICE];
    }
    return result;
}

kern_return_t pg_host_vm(pg_vm_statistics *statistics) {
    vm_statistics64_data_t info = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    host_t host = mach_host_self();
    kern_return_t result = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result == KERN_SUCCESS) {
        statistics->active = info.active_count;
        statistics->inactive = info.inactive_count;
        statistics->wired = info.wire_count;
        statistics->compressor = info.compressor_page_count;
        statistics->free = info.free_count;
    }
    return result;
}

kern_return_t pg_timebase(mach_timebase_info_t info) {
    return mach_timebase_info(info);
}

kern_return_t pg_page_size(vm_size_t *size) {
    host_t host = mach_host_self();
    kern_return_t result = host_page_size(host, size);
    mach_port_deallocate(mach_task_self(), host);
    return result;
}

int pg_boot_session(char *buffer, size_t *size) {
    if (sysctlbyname("kern.bootsessionuuid", buffer, size, NULL, 0) != 0) return errno;
    return 0;
}

int pg_physical_memory(uint64_t *size) {
    size_t length = sizeof(*size);
    if (sysctlbyname("hw.memsize", size, &length, NULL, 0) != 0) return errno;
    return 0;
}

int pg_memory_pressure(int32_t *level) {
    size_t length = sizeof(*level);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", level, &length, NULL, 0) != 0) return errno;
    return length == sizeof(*level) ? 0 : EIO;
}

int pg_swap_usage(struct xsw_usage *usage) {
    size_t length = sizeof(*usage);
    if (sysctlbyname("vm.swapusage", usage, &length, NULL, 0) != 0) return errno;
    return length == sizeof(*usage) ? 0 : EIO;
}
