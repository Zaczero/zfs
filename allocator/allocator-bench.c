#include <linux/module.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/mm.h>
#include <linux/sched/mm.h>
#include <linux/kprobes.h>
#include <linux/ktime.h>

static struct task_struct *runner;
static int phase;
static u64 physical_ns, virtual_ns;
static unsigned int physical_reclaim, virtual_reclaim;
static bool forced, used_virtual;
static gfp_t physical_gfp, virtual_gfp;
static struct page **blocks;
static size_t count, max_blocks;
static bool control;
module_param(control, bool, 0400);

static void fragment(void)
{
	size_t first = count;
	while (count < max_blocks) {
		struct page *p = alloc_pages(GFP_NOWAIT | __GFP_NOWARN, 8);
		if (!p)
			break;
		blocks[count++] = p;
	}
	for (size_t b = first; b < count; b++) {
		split_page(blocks[b], 8);
		for (int i = 0; i < 256; i++)
			if (i % 4)
				__free_page(blocks[b] + i);
	}
}

static int reclaim_enter(struct kprobe *p, struct pt_regs *regs)
{
	if (current == runner) {
		if (phase == 1)
			physical_reclaim++;
		else if (phase == 2)
			virtual_reclaim++;
	}
	return 0;
}
static struct kprobe reclaim_probe = {
	.symbol_name = "try_to_free_pages",
	.pre_handler = reclaim_enter,
};

static void *physical(size_t size, gfp_t flags, int node)
{
	void *p;
	u64 start = ktime_get_ns();
	phase = 1;
	physical_gfp = flags;
	p = forced ? NULL : kmalloc_node(size, flags, node);
	phase = 0;
	physical_ns += ktime_get_ns() - start;
	return p;
}

static void *virtual(size_t size, gfp_t flags)
{
	void *p;
	u64 start = ktime_get_ns();
	phase = 2;
	virtual_gfp = flags;
	used_virtual = true;
	p = __vmalloc(size, flags);
	phase = 0;
	virtual_ns += ktime_get_ns() - start;
	return p;
}
void *original_kvmalloc(size_t, gfp_t);
void *candidate_kvmalloc(size_t, gfp_t);
#undef kmalloc_node
#define kmalloc_node physical
#define spl_vmalloc virtual
#include "allocator-body.inc"
#undef kmalloc_node

static int one(const char *fixture, int candidate, size_t size,
    gfp_t flags, int round)
{
	void *p;
	u64 start, ns;
	unsigned int scope;
	bool expected_fallback = forced && size > PAGE_SIZE &&
	    (flags & __GFP_RECLAIM) == __GFP_RECLAIM;
	physical_ns = virtual_ns = 0;
	physical_reclaim = virtual_reclaim = 0;
	physical_gfp = virtual_gfp = 0;
	used_virtual = false;
	scope = memalloc_noio_save();
	start = ktime_get_ns();
	p = candidate && !control ? candidate_kvmalloc(size, flags) :
	    original_kvmalloc(size, flags);
	if (p) {
		if ((flags & __GFP_ZERO) && memchr_inv(p, 0, size)) {
			kvfree(p);
			memalloc_noio_restore(scope);
			return -EINVAL;
		}
		memset(p, 0x53, size);
		kvfree(p);
	}
	ns = ktime_get_ns() - start;
	memalloc_noio_restore(scope);
	if (forced && (!!p != expected_fallback ||
	    used_virtual != expected_fallback))
		return -EINVAL;
	if (!forced && !p)
		return -ENOMEM;
	if (used_virtual && virtual_gfp != (flags & ~__GFP_COMP))
		return -EINVAL;
	if (candidate && !control && size > PAGE_SIZE &&
	    !(flags & __GFP_RETRY_MAYFAIL) &&
	    (physical_gfp & __GFP_DIRECT_RECLAIM))
		return -EINVAL;
	pr_info("ALLOC_BENCH,%s,%d,%zu,%x,%d,%llu,%llu,%llu,%d,%u,%u\n",
	    fixture, candidate, size, flags, round, ns, physical_ns, virtual_ns,
	    used_virtual, physical_reclaim, virtual_reclaim);
	return 0;
}

static int run(const char *fixture)
{
	static const size_t sizes[] = {8192, 32768, 131072, 1048576};
	static const int order[] = {0, 1, 1, 0};
	for (int s = 0; s < ARRAY_SIZE(sizes); s++)
		for (int r = 0; r < 8; r++)
			for (int a = 0; a < ARRAY_SIZE(order); a++) {
				if (blocks)
					fragment();
				int rc = one(fixture, order[a], sizes[s],
				    GFP_NOIO | __GFP_COMP, r);
				if (rc)
					return rc;
			}
	return 0;
}

static int __init bench_init(void)
{
	int rc;
	gfp_t flags[] = {GFP_NOIO, GFP_NOFS, GFP_NOIO | __GFP_HIGH,
	    GFP_NOIO | __GFP_RETRY_MAYFAIL, GFP_NOWAIT};
	size_t sizes[] = {PAGE_SIZE, PAGE_SIZE + 1,
	    PAGE_SIZE << PAGE_ALLOC_COSTLY_ORDER,
	    (PAGE_SIZE << PAGE_ALLOC_COSTLY_ORDER) + 1, 1048576};
	runner = current;
	rc = register_kprobe(&reclaim_probe);
	if (rc)
		return rc;
	forced = true;
	for (int c = 0; c < 2; c++)
		for (int f = 0; f < ARRAY_SIZE(flags); f++)
			for (int s = 0; s < ARRAY_SIZE(sizes); s++) {
				rc = one("forced", c, sizes[s],
				    flags[f] | __GFP_ZERO | __GFP_COMP, 0);
				if (rc)
					goto out_probe;
			}
	forced = false;
	rc = run("unfragmented");
	if (rc)
		goto out_probe;
	max_blocks = totalram_pages() >> 8;
	blocks = kvcalloc(max_blocks, sizeof (*blocks), GFP_KERNEL);
	if (!blocks) {
		rc = -ENOMEM;
		goto out_probe;
	}
	fragment();
	pr_info("ALLOC_FIXTURE blocks=%zu pinned_pages=%zu total_pages=%lu\n",
	    count, count * 64, totalram_pages());
	rc = run("fragmented");
	for (size_t b = 0; b < count; b++)
		for (int i = 0; i < 256; i += 4)
			__free_page(blocks[b] + i);
	kvfree(blocks);
	blocks = NULL;
	if (!rc)
		rc = run("recovered");
out_probe:
	unregister_kprobe(&reclaim_probe);
	pr_info("ALLOC_RESULT %d\n", rc);
	return rc;
}
static void __exit bench_exit(void) {}
module_init(bench_init);
module_exit(bench_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("SPL speculative allocation flags and fragmentation probe");
