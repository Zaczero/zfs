/* Negative control: ignore output vector boundaries after locating the start. */
#include <string.h>
#include <dlfcn.h>
#include <assert.h>
#include <sys/crypto/impl.h>
#include <sys/uio.h>

int crypto_put_output_data(uchar_t *buf, crypto_data_t *out, int len)
{
	if (out->cd_format == CRYPTO_DATA_UIO) {
		uint_t index;
		off_t off = zfs_uio_index_at_offset(out->cd_uio,
		    out->cd_offset, &index);
		if (len != 0) {
			assert(index < zfs_uio_iovcnt(out->cd_uio));
			memcpy(zfs_uio_iovbase(out->cd_uio, index) + off,
			    buf, len);
		}
		return CRYPTO_SUCCESS;
	}
	int (*real_put)(uchar_t *, crypto_data_t *, int) =
	    dlsym(RTLD_NEXT, "crypto_put_output_data");
	assert(real_put != NULL);
	return real_put(buf, out, len);
}
