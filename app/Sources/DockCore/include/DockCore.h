/*
 * DockCore - talk to a Dell WD19 dock and its Synaptics VMM5331 MST hub from
 * macOS userspace, over the dock's RTS5487 HID-to-I2C bridge (USB 413c:b06e).
 *
 * Protocol follows fwupd's dell-dock plugin (LGPL-2.1+/MIT). Scope is
 * deliberately narrow: status reads plus one allowlisted hub RAM write (the
 * upstream EDID mode nibble at 0x1740). No flash writes, no ESM/HDCP access.
 */

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dc_handle dc_handle;

typedef struct {
	uint8_t hub_major, hub_minor;	/* bridge (RTS5487) firmware */
	uint8_t base_type;		/* 0x04 = Salomon (WD19 family) */
	char marketing_name[65];
	char service_tag[8];
	uint16_t module_type;
	uint16_t board_id;
	uint16_t power_supply_watts;
	uint32_t package_version;
	uint8_t mst_version[3];		/* e.g. 05.06.03 */
	int has_mst_version;
} dc_dock_info;

typedef struct {
	uint8_t bootloader_status[4];
	int active_bank;
	int running_firmware;		/* 1 = firmware, 0 = bootloader */
	uint8_t fw_version_reg[4];
} dc_mst_status;

/* Upstream EDID modes (hub RAM 0x1740 low nibble). */
enum {
	DC_EDID_MODE_AGGREGATE = 2,	/* ViewXpand: one wide display, split */
	DC_EDID_MODE_PASSTHROUGH = 3,	/* Dell default: first monitor's EDID */
};

#define DC_RAM_CONFIG	0x1700	/* RAM copy of flash config block 0x100 */
#define DC_RAM_EDID_MODE 0x1740
#define DC_RAM_EDID	0x1600	/* EDID presented to the computer */
#define DC_RAM_PORTS	0x1820	/* +1: low nibble = connected monitors */

/* Returns 0 on success, -1 on failure (see dc_last_error). */
int dc_open(dc_handle **out);
void dc_close(dc_handle *h);
const char *dc_last_error(const dc_handle *h);

int dc_dock_info_read(dc_handle *h, dc_dock_info *out);
int dc_mst_status_read(dc_handle *h, dc_mst_status *out);
int dc_mst_read_memory(dc_handle *h, uint32_t addr, uint32_t len, uint8_t *out);
int dc_mst_read_flash(dc_handle *h, uint32_t offset, uint32_t len, uint8_t *out,
		      void (*progress)(uint32_t done, uint32_t total, void *ctx), void *ctx);
int dc_mst_checksum(dc_handle *h, uint32_t start, uint32_t len, uint32_t *sum);
int dc_mst_read_register(dc_handle *h, uint32_t addr, uint32_t len, uint8_t *out);

/*
 * The only write: set the low nibble of hub RAM 0x1740 (0..4). RAM only; a dock
 * power-cycle restores the flash value. before/after may be NULL.
 */
int dc_mst_set_edid_mode(dc_handle *h, uint8_t mode, uint8_t before[4], uint8_t after[4]);

#ifdef __cplusplus
}
#endif
