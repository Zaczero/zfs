PROBE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: review-probes
review-probes: libzpool.la libnvpair.la
	$(LIBTOOL) --mode=link $(CC) $(AM_CPPFLAGS) $(LIBZPOOL_CPPFLAGS) \
	    -I$(srcdir)/module/icp/include $(CFLAGS) -o $(OUT)/cleanup_probe \
	    $(PROBE_DIR)/cleanup_probe.c libzpool.la libnvpair.la
	$(LIBTOOL) --mode=link $(CC) $(AM_CPPFLAGS) $(LIBZPOOL_CPPFLAGS) \
	    $(CFLAGS) -o $(OUT)/allocation_probe \
	    $(PROBE_DIR)/allocation_probe.c libzpool.la libnvpair.la

.PHONY: scatter-mutant
scatter-mutant:
	$(CC) $(AM_CPPFLAGS) $(LIBZPOOL_CPPFLAGS) \
	    -I$(srcdir)/module/icp/include $(CFLAGS) -shared -fPIC \
	    -o $(OUT)/scatter_mutant.so $(PROBE_DIR)/scatter_mutant.c \
	    -ldl
