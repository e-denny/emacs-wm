#define _GNU_SOURCE
/* Minimal layer-shell "bar": a 30px strip anchored to the top of the output
 * with an exclusive zone of 30px. Exists to test that
 * river_layer_shell_output_v1.non_exclusive_area reaches the WM and that the WM
 * sizes its desktop frames to the space that is left.
 *
 * build: gcc -o testbar testbar.c layer-shell-protocol.c \
 *            $(pkg-config --cflags --libs wayland-client)
 * run:   WAYLAND_DISPLAY=wayland-N ./testbar
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "layer-shell-client.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct zwlr_layer_shell_v1 *shell;
static struct wl_output *output;

static void
registry_global(void *d, struct wl_registry *r, uint32_t name,
                const char *iface, uint32_t version)
{
	(void)d; (void)version;
	if (!strcmp(iface, "wl_compositor"))
		compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
	else if (!strcmp(iface, "wl_shm"))
		shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
	else if (!strcmp(iface, "wl_output"))
		output = wl_registry_bind(r, name, &wl_output_interface, 4);
	else if (!strcmp(iface, "zwlr_layer_shell_v1"))
		shell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, 4);
}
static void registry_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = { registry_global, registry_remove };

static struct wl_buffer *
make_buffer(int w, int h)
{
	int stride = w * 4, size = stride * h;
	int fd = memfd_create("testbar", 0);
	if (fd < 0 || ftruncate(fd, size) < 0) { perror("testbar"); exit(1); }
	void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) { perror("testbar mmap"); exit(1); }
	uint32_t *pixels = data;
	for (int i = 0; i < w * h; i++)
		pixels[i] = 0xff2a2a3a; /* dull blue */
	munmap(data, size);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
	struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
	                                                  WL_SHM_FORMAT_XRGB8888);
	close(fd);
	wl_shm_pool_destroy(pool);
	return buf;
}

static void
layer_configure(void *d, struct zwlr_layer_surface_v1 *ls, uint32_t serial,
                uint32_t w, uint32_t h)
{
	struct wl_surface *surface = d;
	if (w == 0) w = 800;
	if (h == 0) h = 30;
	fprintf(stderr, "testbar: configure %ux%u\n", w, h);
	struct wl_buffer *buf = make_buffer((int)w, (int)h);
	wl_surface_attach(surface, buf, 0, 0);
	wl_surface_damage_buffer(surface, 0, 0, (int)w, (int)h);
	zwlr_layer_surface_v1_ack_configure(ls, serial);
	wl_surface_commit(surface);
}
static void layer_closed(void *d, struct zwlr_layer_surface_v1 *ls) { (void)d; (void)ls; exit(0); }
static const struct zwlr_layer_surface_v1_listener layer_listener = { layer_configure, layer_closed };

int
main(void)
{
	struct wl_display *display = wl_display_connect(NULL);
	if (!display) { fprintf(stderr, "testbar: no wayland display\n"); return 1; }
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);
	wl_display_roundtrip(display);
	if (!compositor || !shm || !shell) {
		fprintf(stderr, "testbar: missing globals (compositor=%p shm=%p shell=%p)\n",
		        (void *)compositor, (void *)shm, (void *)shell);
		return 1;
	}

	struct wl_surface *surface = wl_compositor_create_surface(compositor);
	struct zwlr_layer_surface_v1 *ls = zwlr_layer_shell_v1_get_layer_surface(
		shell, surface, output, ZWLR_LAYER_SHELL_V1_LAYER_TOP, "testbar");
	zwlr_layer_surface_v1_add_listener(ls, &layer_listener, surface);
	zwlr_layer_surface_v1_set_anchor(ls,
		ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
	zwlr_layer_surface_v1_set_size(ls, 0, 30);
	zwlr_layer_surface_v1_set_exclusive_zone(ls, 30);
	wl_surface_commit(surface);
	fprintf(stderr, "testbar: mapped, waiting for configure\n");
	while (wl_display_dispatch(display) != -1)
		;
	return 0;
}
