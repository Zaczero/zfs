/* Disposable-guest allocation progress check, not a latency benchmark. */
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/mm.h>
#include <linux/sched/mm.h>
#include <linux/kprobes.h>
#include <linux/vmstat.h>

static bool candidate;
static unsigned long size = 8192;
module_param(candidate, bool, 0400);
module_param(size, ulong, 0400);
static struct task_struct *runner;
static int phase;
static unsigned int physical_reclaim, virtual_reclaim, fallbacks;
static bool bad_mask;

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

static void *physical(size_t n, gfp_t flags, int node)
{
	void *p;
	if (candidate && (flags & __GFP_DIRECT_RECLAIM))
		bad_mask = true;
	phase = 1;
	p = kmalloc_node(n, flags, node);
	phase = 0;
	return p;
}

static void *virtual(size_t n, gfp_t flags)
{
	void *p;
	if (flags != (GFP_NOIO | __GFP_ZERO))
		bad_mask = true;
	fallbacks++;
	phase = 2;
	p = __vmalloc(n, flags);
	phase = 0;
	return p;
}

void *original_kvmalloc(size_t, gfp_t);
void *candidate_kvmalloc(size_t, gfp_t);
#undef kmalloc_node
#define kmalloc_node physical
#define spl_vmalloc virtual
#include "allocator-body.inc"
#undef kmalloc_node

static int __init pressure_init(void)
{
	unsigned long target = totalram_pages() * 65 / 100;
	unsigned long bytes = (totalram_pages() / 16) << PAGE_SHIFT;
	unsigned long requests, pinned = 0, allocated = 0;
	struct page **pages;
	void **buffers;
	unsigned int scope;
	int rc;

	if (size <= PAGE_SIZE || size > 1048576)
		return -EINVAL;
	requests = bytes / size;
	pages = kvcalloc(target, sizeof (*pages), GFP_KERNEL);
	buffers = kvcalloc(requests, sizeof (*buffers), GFP_KERNEL);
	if (!pages || !buffers) {
		rc = -ENOMEM;
		goto out;
	}
	runner = current;
	rc = register_kprobe(&reclaim_probe);
	if (rc)
		goto out;
	for (; pinned < target; pinned++) {
		pages[pinned] = alloc_page(GFP_KERNEL | __GFP_NOWARN);
		if (!pages[pinned]) {
			rc = -ENOMEM;
			goto out_probe;
		}
	}
	pr_info("PRESSURE_START candidate=%d size=%lu pinned=%lu "
	    "free_pages=%lu file_pages=%lu requests=%lu\n",
	    candidate, size, pinned, global_zone_page_state(NR_FREE_PAGES),
	    global_node_page_state(NR_FILE_PAGES), requests);
	scope = memalloc_noio_save();
	for (; allocated < requests; allocated++) {
		void *p = candidate ?
		    candidate_kvmalloc(size, GFP_NOIO | __GFP_COMP | __GFP_ZERO) :
		    original_kvmalloc(size, GFP_NOIO | __GFP_COMP | __GFP_ZERO);
		if (!p) {
			rc = -ENOMEM;
			break;
		}
		buffers[allocated] = p;
		if (memchr_inv(p, 0, size)) {
			allocated++;
			rc = -EINVAL;
			break;
		}
		memset(p, 0x53, size);
	}
	memalloc_noio_restore(scope);
	if (bad_mask || (candidate && physical_reclaim))
		rc = -EINVAL;
	pr_info("PRESSURE_RESULT candidate=%d size=%lu allocated=%lu "
	    "fallbacks=%u physical_reclaim=%u virtual_reclaim=%u rc=%d\n",
	    candidate, size, allocated, fallbacks, physical_reclaim,
	    virtual_reclaim, rc);
out_probe:
	unregister_kprobe(&reclaim_probe);
out:
	for (unsigned long i = 0; i < allocated; i++) {
		if (memchr_inv(buffers[i], 0x53, size))
			rc = -EINVAL;
		kvfree(buffers[i]);
	}
	for (unsigned long i = 0; i < pinned; i++)
		__free_page(pages[i]);
	kvfree(buffers);
	kvfree(pages);
	pr_info("PRESSURE_DONE rc=%d\n", rc);
	return rc;
}

static void __exit pressure_exit(void) {}
module_init(pressure_init);
module_exit(pressure_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("SPL allocation progress under reclaimable memory pressure");
