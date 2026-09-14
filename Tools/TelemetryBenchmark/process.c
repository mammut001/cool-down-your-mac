#include <libproc.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <mach/mach_time.h>

// Read-only cumulative process counters, sampled over one shared interval.
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    int seconds = atoi(argv[1]);
    if (seconds < 1 || seconds > 60 || argc > 18) return 2;
    struct rusage_info_v4 before[16] = {0}, after[16] = {0};
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    for (int i = 2; i < argc; i++) {
        if (proc_pid_rusage(atoi(argv[i]), RUSAGE_INFO_V4, (rusage_info_t *)&before[i-2])) {
            perror("proc_pid_rusage"); return 1;
        }
    }
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    sleep(seconds);
    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec-start.tv_sec) + (end.tv_nsec-start.tv_nsec)/1e9;
    for (int i = 2; i < argc; i++) {
        if (proc_pid_rusage(atoi(argv[i]), RUSAGE_INFO_V4, (rusage_info_t *)&after[i-2])) {
            perror("proc_pid_rusage"); return 1;
        }
        struct rusage_info_v4 a = after[i-2], b = before[i-2];
        double cpu = ((a.ri_user_time-b.ri_user_time)+(a.ri_system_time-b.ri_system_time))
            * (double)timebase.numer / timebase.denom / 1e9;
        printf("pid=%s seconds=%.2f cpu_percent=%.3f footprint_MiB=%.1f interrupt_wakeups_per_s=%.2f idle_wakeups_per_s=%.2f\n",
            argv[i], elapsed, cpu/elapsed*100, a.ri_phys_footprint/1048576.0,
            (a.ri_interrupt_wkups-b.ri_interrupt_wkups)/elapsed,
            (a.ri_pkg_idle_wkups-b.ri_pkg_idle_wkups)/elapsed);
    }
}
