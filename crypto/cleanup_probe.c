/* Native libzpool cleanup check; glibc malloc/free observation only. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/zfs_context.h>
#include <sys/crypto/icp.h>
#include <aes/aes_impl.h>
#include <modes/modes.h>

extern void *__libc_malloc(size_t);
extern void __libc_free(void *);
static int tracking;
static void *allocated, *watched;
static size_t allocated_size, watched_size, nonzero_at_free;
static int freed;

void *malloc(size_t n)
{
	void *p = __libc_malloc(n);
	if (tracking && p != NULL) {
		assert(allocated == NULL);
		allocated = p;
		allocated_size = n;
		memset(p, 0xa5, n);
	}
	return p;
}

void free(void *p)
{
	if (p != NULL && p == watched) {
		for (size_t n = 0; n < watched_size; n++)
			nonzero_at_free += ((unsigned char *)p)[n] != 0;
		freed = 1;
	}
	__libc_free(p);
}

int main(void)
{
	icp_init();
	assert(aes_impl_set("aesni") == 0);
	unsigned char key[32], iv[12];
	memset(key, 0x41, sizeof (key));
	memset(iv, 0x52, sizeof (iv));
	CK_AES_GCM_PARAMS params = {
		.pIv = iv, .ulIvLen = sizeof (iv), .ulIvBits = 96,
		.ulTagBits = 128
	};
	const char *impls[] = {"avx", "avx2-vaes"};
	int failures = 0, tested = 0;
	for (size_t n = 0; n < sizeof (impls) / sizeof (*impls); n++) {
		if (gcm_impl_set(impls[n]) != 0) {
			printf("%s unsupported\n", impls[n]);
			continue;
		}
		gcm_ctx_t ctx = {0};
		size_t keysched_size;
		ctx.gcm_keysched = aes_alloc_keysched(&keysched_size, KM_SLEEP);
		assert(ctx.gcm_keysched != NULL);
		aes_init_keysched(key, 256, ctx.gcm_keysched);
		allocated = watched = NULL;
		allocated_size = watched_size = nonzero_at_free = 0;
		freed = 0;
		tracking = 1;
		int rc = gcm_init_ctx(&ctx, (char *)&params, AES_BLOCK_LEN,
		    aes_encrypt_block, aes_copy_block, aes_xor_block);
		tracking = 0;
		assert(rc == CRYPTO_SUCCESS);
		assert(ctx.gcm_Htable == allocated && allocated != NULL);
		watched = allocated;
		watched_size = allocated_size;
		size_t recorded = ctx.gcm_htab_len;
		gcm_clear_ctx(&ctx);
		printf("%s allocated=%zu recorded=%zu freed=%d "
		    "nonzero_at_free=%zu\n", impls[n], allocated_size,
		    recorded, freed, nonzero_at_free);
		failures += recorded != allocated_size ||
		    !freed || nonzero_at_free != 0;
		watched = NULL;
		kmem_free(ctx.gcm_keysched, keysched_size);
		tested++;
	}
	icp_fini();
	return tested == 0 ? 77 : failures != 0;
}
