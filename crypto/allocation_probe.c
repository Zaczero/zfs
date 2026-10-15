#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <sys/crypto/icp.h>
#include <sys/crypto/api.h>
#include <sys/uio.h>

extern void *__libc_malloc(size_t);
extern void __libc_free(void *);
static int tracking;
static struct { void *p; size_t n; } allocations[4096];
static size_t count, live, peak, total, large_count;

void *malloc(size_t n)
{
	void *p = __libc_malloc(n);
	if (tracking && p != NULL) {
		size_t i;
		for (i = 0; i < 4096 && allocations[i].p != NULL; i++) {}
		assert(i != 4096);
		allocations[i].p = p;
		allocations[i].n = n;
		count++;
		total += n;
		live += n;
		if (n >= 1024 * 1024)
			large_count++;
		if (live > peak)
			peak = live;
	}
	return (p);
}

void free(void *p)
{
	for (size_t i = 0; i < 4096; i++)
		if (p != NULL && allocations[i].p == p) {
			live -= allocations[i].n;
			allocations[i].p = NULL;
			break;
		}
	__libc_free(p);
}

static void begin(void)
{
	assert(live == 0);
	count = peak = total = large_count = 0;
	tracking = 1;
}

static void end(const char *name, int rc)
{
	tracking = 0;
	printf("%s rc=%d allocations=%zu large=%zu bytes=%zu peak=%zu leaked=%zu\n",
	    name, rc, count, large_count, total, peak, live);
	/* Reclaim deliberately reproduced leaks between independent cases. */
	for (size_t i = 0; i < 4096; i++)
		if (allocations[i].p != NULL)
			free(allocations[i].p);
}

static crypto_data_t raw(char *p, size_t n)
{
	crypto_data_t d = { .cd_format = CRYPTO_DATA_RAW,
	    .cd_length = n, .cd_raw = { .iov_base = p, .iov_len = n } };
	return (d);
}

int main(int argc, char **argv)
{
	icp_init();
	unsigned char keydata[32], iv[12], aad[7];
	memset(keydata, 0x41, sizeof (keydata));
	memset(iv, 0x52, sizeof (iv));
	memset(aad, 0x63, sizeof (aad));
	crypto_key_t key = { .ck_data = keydata, .ck_length = 256 };
	CK_AES_GCM_PARAMS params = { .pIv = iv, .ulIvLen = sizeof (iv),
	    .ulIvBits = 96, .pAAD = aad, .ulAADLen = sizeof (aad),
	    .ulTagBits = 128 };
	crypto_mechanism_t mech = { .cm_type = crypto_mech2id(SUN_CKM_AES_GCM),
	    .cm_param = (char *)&params, .cm_param_len = sizeof (params) };
	const size_t n = argc > 1 ? strtoul(argv[1], NULL, 10) : 1024 * 1024;
	assert(n > 0 && n <= 1024 * 1024 && n % 4096 == 0);
	const size_t chunk = argc > 2 ? strtoul(argv[2], NULL, 10) : 4096;
	assert(chunk >= 4096 && chunk <= n && n % chunk == 0);
	char *plain = malloc(n), *cipher = malloc(n + 16), *out = malloc(n + 16);
	for (size_t i = 0; i < n; i++)
		plain[i] = (char)(0x21 + i % 173);
	const char *impls[] = { "generic", "avx", "avx2-vaes" };
	for (size_t impl = 0; impl < 3; impl++) {
		if (gcm_impl_set(impls[impl]) != 0)
			continue;
		printf("implementation=%s\n", impls[impl]);
		crypto_data_t p = raw(plain, n), c = raw(cipher, n + 16);
		assert(crypto_encrypt(&mech, &p, &key, NULL, &c) == CRYPTO_SUCCESS);
		for (int layout = 0; layout < 3; layout++) {
			iovec_t vec[260];
			char prefix[5] = {0x31, 0x42, 0x53, 0x64, 0x75};
			int nv = 0;
			if (layout == 1) {
				vec[nv++] = (iovec_t){cipher, n};
				vec[nv++] = (iovec_t){cipher + n, 16};
			} else if (layout == 2) {
				vec[nv++] = (iovec_t){prefix, sizeof (prefix)};
				vec[nv++] = (iovec_t){cipher, 0};
				for (size_t off = 0; off < n; off += chunk)
					vec[nv++] = (iovec_t){cipher + off, chunk};
				vec[nv++] = (iovec_t){cipher + n, 7};
				vec[nv++] = (iovec_t){cipher + n + 7, 9};
			}
			zfs_uio_t uio = {0};
			zfs_uio_iov(&uio) = vec;
			zfs_uio_iovcnt(&uio) = nv;
			zfs_uio_segflg(&uio) = UIO_SYSSPACE;
			c = raw(cipher, n + 16);
			if (layout != 0) {
				c.cd_format = CRYPTO_DATA_UIO;
				c.cd_uio = &uio;
				if (layout == 2)
					c.cd_offset = sizeof (prefix);
			}
			for (int bad = 0; bad < 2; bad++) {
				memset(out, 0x75, n + 16);
				crypto_data_t o = raw(out, n + 16);
				char guard[5];
				memset(guard, 0x29, sizeof (guard));
				iovec_t output_vec[] = {
					{guard, sizeof (guard)}, {out, n / 2},
					{out + n / 2, n / 2 + 16}
				};
				zfs_uio_t output_uio = {0};
				if (layout == 2) {
					zfs_uio_iov(&output_uio) = output_vec;
					zfs_uio_iovcnt(&output_uio) = 3;
					zfs_uio_segflg(&output_uio) = UIO_SYSSPACE;
					o.cd_format = CRYPTO_DATA_UIO;
					o.cd_uio = &output_uio;
					o.cd_offset = sizeof (guard);
				}
				if (bad)
					cipher[n + 15] ^= 1;
				begin();
				int rc = crypto_decrypt(&mech, &c, &key, NULL, &o);
				end(layout == 0 ? "raw" : layout == 1 ? "split" : "fragmented", rc);
				assert(o.cd_offset == (layout == 2 ? sizeof (guard) : 0));
				for (size_t i = 0; i < sizeof (guard); i++)
					assert(guard[i] == 0x29);
				if (bad) {
					assert(rc == CRYPTO_INVALID_MAC);
					for (size_t i = 0; i < n + 16; i++)
						assert((unsigned char)out[i] == 0x75);
					cipher[n + 15] ^= 1;
				} else {
					assert(rc == CRYPTO_SUCCESS);
					assert(memcmp(plain, out, n) == 0);
				}
			}
		}
		for (int truncated = 0; truncated < 2; truncated++) {
			iovec_t vec[] = {
				{cipher, n}, {cipher + n, 16 - truncated}
			};
			zfs_uio_t uio = {0};
			zfs_uio_iov(&uio) = vec;
			zfs_uio_iovcnt(&uio) = 2;
			zfs_uio_segflg(&uio) = UIO_SYSSPACE;
			c = raw(cipher, n + 16);
			c.cd_format = CRYPTO_DATA_UIO;
			c.cd_uio = &uio;
			crypto_data_t o = raw(out, truncated ? n : n - 1);
			memset(out, 0x75, n + 16);
			begin();
			int rc = crypto_decrypt(&mech, &c, &key, NULL, &o);
			size_t leaked = live;
			end(truncated ? "truncated-input" : "short-output", rc);
			assert(rc == (truncated ?
			    CRYPTO_DATA_LEN_RANGE : CRYPTO_BUFFER_TOO_SMALL));
			assert(leaked == 0 && o.cd_length == n && o.cd_offset == 0);
			for (size_t i = 0; i < n + 16; i++)
				assert((unsigned char)out[i] == 0x75);
		}
		p = raw(plain, 0);
		c = raw(cipher, 16);
		assert(crypto_encrypt(&mech, &p, &key, NULL, &c) == CRYPTO_SUCCESS);
		crypto_data_t o = raw(out, 16);
		memset(out, 0x75, 16);
		begin();
		int rc = crypto_decrypt(&mech, &c, &key, NULL, &o);
		end("tag-only", rc);
		assert(rc == CRYPTO_SUCCESS);
		assert(o.cd_length == 0);
		for (size_t i = 0; i < 16; i++)
			assert(out[i] == 0x75);
		c = raw(cipher, 15);
		o = raw(out, 16);
		begin();
		rc = crypto_decrypt(&mech, &c, &key, NULL, &o);
		end("short-tag", rc);
		assert(rc != CRYPTO_SUCCESS);
		for (size_t i = 0; i < 16; i++)
			assert(out[i] == 0x75);
	}
	for (int mode = 0; mode < 2; mode++) {
		mech.cm_type = crypto_mech2id(mode ? SUN_CKM_AES_CCM : SUN_CKM_AES_GCM);
		mech.cm_param = NULL;
		for (int sized = 0; sized < 2; sized++) {
			mech.cm_param_len = !sized ? 0 : mode ?
			    sizeof (CK_AES_CCM_PARAMS) : sizeof (params);
			for (int decrypt = 0; decrypt < 2; decrypt++) {
				crypto_data_t p = raw(plain, n), c = raw(cipher, n + 16);
				char *output = decrypt ? plain : cipher;
				size_t length = decrypt ? n : n + 16;
				memset(output, 0x75, length);
				begin();
				int rc = decrypt ? crypto_decrypt(&mech, &c, &key, NULL, &p) :
				    crypto_encrypt(&mech, &p, &key, NULL, &c);
				tracking = 0;
				char label[80];
				snprintf(label, sizeof (label), "null-%s-%s-params%zu",
				    mode ? "CCM" : "GCM", decrypt ? "decrypt" : "encrypt",
				    mech.cm_param_len);
				end(label, rc);
				assert(rc == CRYPTO_MECHANISM_PARAM_INVALID);
				assert((decrypt ? p.cd_length : c.cd_length) == length);
				assert((decrypt ? p.cd_offset : c.cd_offset) == 0);
				for (size_t i = 0; i < length; i++)
					assert((unsigned char)output[i] == 0x75);
			}
		}
	}
	free(plain);
	free(cipher);
	free(out);
	icp_fini();
	return (0);
}
