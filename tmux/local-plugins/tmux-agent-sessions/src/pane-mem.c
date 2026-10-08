/*
 * pane-mem-darwin: per-process-tree physical footprint for tmux panes.
 *
 * Usage: pane-mem-darwin PID...
 *
 * For every argument that names a live process, prints one line
 * "PID KIB", where KIB is the sum of ri_phys_footprint (in KiB) over that
 * process and all of its descendants. Roots that are not alive (or are not
 * valid pids) print nothing. Always exits 0 unless memory allocation fails.
 *
 * Footprint is what Activity Monitor's "Memory" column shows. Unlike RSS it
 * includes compressed pages, so idle processes are not hidden. It overcounts
 * shared and graphics memory, so the numbers rank panes rather than add up
 * to a system total.
 *
 * Processes we cannot read (other users, sandbox denials) contribute 0 but
 * still link the tree, so a root-owned child does not hide its own
 * user-owned descendants.
 *
 * Build: clang -O2 -o bin/pane-mem-darwin src/pane-mem.c
 */

#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/types.h>

struct proc_ent {
    pid_t pid;
    pid_t ppid;          /* -1 when unknown */
    unsigned long long kib;
};

static struct proc_ent *procs;
static int nprocs;

static int cmp_pid(const void *a, const void *b)
{
    pid_t x = ((const struct proc_ent *)a)->pid;
    pid_t y = ((const struct proc_ent *)b)->pid;
    return (x > y) - (x < y);
}

static int find_index(pid_t pid)
{
    int lo = 0, hi = nprocs - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        if (procs[mid].pid == pid)
            return mid;
        if (procs[mid].pid < pid)
            lo = mid + 1;
        else
            hi = mid - 1;
    }
    return -1;
}

static int parse_pid(const char *s, pid_t *out)
{
    long v = 0;
    if (*s == '\0')
        return 0;
    for (; *s; s++) {
        if (*s < '0' || *s > '9')
            return 0;
        v = v * 10 + (*s - '0');
        if (v > INT32_MAX)
            return 0;
    }
    if (v <= 0)
        return 0;
    *out = (pid_t)v;
    return 1;
}

/* Snapshot every pid with its parent and footprint. */
static int snapshot(void)
{
    pid_t *pids = NULL;
    int cap, n;

    n = proc_listallpids(NULL, 0);
    if (n <= 0)
        return -1;
    for (;;) {
        cap = n + 256;
        free(pids);
        pids = malloc((size_t)cap * sizeof(pid_t));
        if (pids == NULL)
            return -1;
        n = proc_listallpids(pids, cap * (int)sizeof(pid_t));
        if (n < 0) {
            free(pids);
            return -1;
        }
        if (n < cap)
            break;
        /* Buffer was filled exactly: the table grew, retry larger. */
    }

    procs = malloc((size_t)(n > 0 ? n : 1) * sizeof(*procs));
    if (procs == NULL) {
        free(pids);
        return -1;
    }

    nprocs = 0;
    for (int i = 0; i < n; i++) {
        struct proc_bsdshortinfo si;
        struct rusage_info_v4 ri;
        struct proc_ent *e;
        pid_t pid = pids[i];

        if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof(si))
            == (int)sizeof(si)) {
            e = &procs[nprocs++];
            e->pid = pid;
            e->ppid = (pid_t)si.pbsi_ppid;
        } else if (pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)) {
            /* Alive but unreadable: keep it as a possible root. */
            e = &procs[nprocs++];
            e->pid = pid;
            e->ppid = -1;
        } else {
            continue; /* exited since the listing */
        }

        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0)
            e->kib = ri.ri_phys_footprint / 1024;
        else
            e->kib = 0;
    }
    free(pids);

    qsort(procs, (size_t)nprocs, sizeof(*procs), cmp_pid);
    return 0;
}

int main(int argc, char **argv)
{
    int *child_start, *children, *stack;
    unsigned *seen;
    unsigned gen = 0;

    if (argc < 2)
        return 0;
    if (snapshot() != 0)
        return 0; /* no data: behave as if every root were dead */

    /* Children in CSR form, indexed by parent's position in procs. */
    child_start = calloc((size_t)nprocs + 1, sizeof(int));
    children = malloc((size_t)(nprocs > 0 ? nprocs : 1) * sizeof(int));
    stack = malloc((size_t)(nprocs > 0 ? nprocs : 1) * sizeof(int));
    seen = calloc((size_t)(nprocs > 0 ? nprocs : 1), sizeof(unsigned));
    if (!child_start || !children || !stack || !seen)
        return 1;

    int *parent_idx = malloc((size_t)(nprocs > 0 ? nprocs : 1) * sizeof(int));
    if (!parent_idx)
        return 1;
    for (int i = 0; i < nprocs; i++) {
        int p = -1;
        if (procs[i].ppid >= 0 && procs[i].ppid != procs[i].pid)
            p = find_index(procs[i].ppid);
        parent_idx[i] = p;
        if (p >= 0)
            child_start[p + 1]++;
    }
    for (int i = 0; i < nprocs; i++)
        child_start[i + 1] += child_start[i];
    {
        int *fill = malloc((size_t)(nprocs > 0 ? nprocs : 1) * sizeof(int));
        if (!fill)
            return 1;
        for (int i = 0; i < nprocs; i++)
            fill[i] = child_start[i];
        for (int i = 0; i < nprocs; i++)
            if (parent_idx[i] >= 0)
                children[fill[parent_idx[i]]++] = i;
        free(fill);
    }

    for (int a = 1; a < argc; a++) {
        pid_t root;
        int ri, sp = 0;
        unsigned long long sum = 0;

        if (!parse_pid(argv[a], &root))
            continue;
        ri = find_index(root);
        if (ri < 0)
            continue;

        gen++;
        seen[ri] = gen;
        stack[sp++] = ri;
        while (sp > 0) {
            int cur = stack[--sp];
            sum += procs[cur].kib;
            for (int c = child_start[cur]; c < child_start[cur + 1]; c++) {
                int k = children[c];
                if (seen[k] != gen) { /* guards against ppid cycles */
                    seen[k] = gen;
                    stack[sp++] = k;
                }
            }
        }
        printf("%d %llu\n", (int)root, sum);
    }
    return 0;
}
