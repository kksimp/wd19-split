/*
 * DockCore implementation. See DockCore.h for scope.
 *
 * Every MST operation runs inside a short session: ask the EC for MST bus
 * access (modify-lock target 9), optionally enable MST remote control (RC),
 * do the work, then disable RC and re-lock - also on every error path.
 */

#include "DockCore.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DELL_VID	0x413c
#define BRIDGE_PID	0xb06e
#define REPORT_SIZE	192
#define HID_RETRIES	5

#define HUB_CMD_READ_DATA	0xC0
#define HUB_CMD_WRITE_DATA	0x40
#define HUB_EXT_READ_STATUS	0x09
#define HUB_EXT_I2C_WRITE	0xC6
#define HUB_EXT_I2C_READ	0xD6

#define I2C_SPEED_250K 0
#define I2C_SPEED_400K 1

#define I2C_EC_ADDRESS		0xec
#define EC_CMD_GET_DOCK_INFO	0x02
#define EC_CMD_GET_DOCK_DATA	0x03
#define EC_CMD_GET_DOCK_TYPE	0x05
#define EC_CMD_MODIFY_LOCK	0x0a
#define EC_DOCK_INFO_SIZE	0xb7
#define EC_DOCK_DATA_SIZE	103
#define DOCK_BASE_TYPE_SALOMON	0x04
#define MST_UNLOCK_TARGET	9

#define I2C_MST_ADDRESS 0x72
#define PANAMERA_MST_RC_TRIGGER_ADDR	     0x2000fc
#define PANAMERA_MST_CORE_MCU_BOOTLOADER_STS 0x20010c
#define PANAMERA_MST_RC_COMMAND_ADDR	     0x200110
#define PANAMERA_MST_RC_DATA_ADDR	     0x200120
#define PANAMERA_MST_CORE_MCU_FW_VERSION     0x200160
#define MST_TRIGGER_WRITE 0xf2

#define MST_CMD_ENABLE_RC    0x01
#define MST_CMD_DISABLE_RC   0x02
#define MST_CMD_CHECKSUM     0x11
#define MST_CMD_WRITE_MEMORY 0x21
#define MST_CMD_READ_FLASH   0x30
#define MST_CMD_READ_MEMORY  0x31

#define MST_CHUNK 32

typedef struct __attribute__((packed)) {
	uint8_t i2ctargetaddr;
	uint8_t regaddrlen;
	uint8_t i2cspeed;
} I2CParams;

typedef struct __attribute__((packed)) {
	uint8_t cmd;
	uint8_t ext;
	uint32_t dwregaddr;
	uint16_t bufferlen;
	I2CParams parameters;
	uint8_t extended_cmdarea[53];
	uint8_t data[192];
} CmdBuffer;

static const I2CParams ec_params = {I2C_EC_ADDRESS, 1, I2C_SPEED_250K};
static const I2CParams mst_params = {I2C_MST_ADDRESS, 0, I2C_SPEED_400K};

struct dc_handle {
	IOHIDDeviceRef dev;
	int unlocked;
	int rc_enabled;
	char err[256];
};

static int
fail(dc_handle *h, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(h->err, sizeof(h->err), fmt, ap);
	va_end(ap);
	return -1;
}

const char *
dc_last_error(const dc_handle *h)
{
	return h ? h->err : "no handle";
}

/* ---- HID transport ---- */

static int
hid_set(dc_handle *h, const uint8_t *buf)
{
	for (int i = 0; i < HID_RETRIES; i++) {
		if (IOHIDDeviceSetReport(h->dev, kIOHIDReportTypeOutput, 0, buf, REPORT_SIZE) == kIOReturnSuccess)
			return 0;
		usleep(10000);
	}
	return fail(h, "HID set report failed");
}

static int
hid_get(dc_handle *h, uint8_t *buf)
{
	for (int i = 0; i < HID_RETRIES; i++) {
		CFIndex len = REPORT_SIZE;
		if (IOHIDDeviceGetReport(h->dev, kIOHIDReportTypeInput, 0, buf, &len) == kIOReturnSuccess)
			return 0;
		usleep(10000);
	}
	return fail(h, "HID get report failed");
}

static int
i2c_write(dc_handle *h, const I2CParams *p, const uint8_t *data, size_t len)
{
	CmdBuffer c = {0};
	if (len > 128)
		return fail(h, "I2C write too long");
	c.cmd = HUB_CMD_WRITE_DATA;
	c.ext = HUB_EXT_I2C_WRITE;
	c.bufferlen = (uint16_t)len;
	c.parameters.i2ctargetaddr = p->i2ctargetaddr;
	c.parameters.i2cspeed = p->i2cspeed | 0x80;
	memcpy(c.data, data, len);
	return hid_set(h, (uint8_t *)&c);
}

static int
i2c_read(dc_handle *h, const I2CParams *p, uint32_t reg, size_t len, uint8_t *out)
{
	CmdBuffer c = {0};
	if (len > REPORT_SIZE)
		return fail(h, "I2C read too long");
	c.cmd = HUB_CMD_WRITE_DATA;
	c.ext = HUB_EXT_I2C_READ;
	c.dwregaddr = reg;
	c.bufferlen = (uint16_t)len;
	c.parameters = *p;
	c.parameters.i2cspeed |= 0x80;
	if (hid_set(h, (uint8_t *)&c) || hid_get(h, c.data))
		return -1;
	memcpy(out, c.data, len);
	return 0;
}

/* ---- EC ---- */

static int
ec_read(dc_handle *h, uint8_t cmd, size_t len, uint8_t *out)
{
	uint8_t buf[REPORT_SIZE];
	if (i2c_read(h, &ec_params, cmd, len + 1, buf))
		return -1;
	if (buf[0] != len)
		return fail(h, "EC cmd 0x%02x returned %u bytes, expected %zu", cmd, buf[0], len);
	memcpy(out, buf + 1, len);
	return 0;
}

static int
ec_modify_lock(dc_handle *h, uint8_t target, int unlocked)
{
	uint32_t cmd = EC_CMD_MODIFY_LOCK | 2 << 8 | (uint32_t)target << 16 | (uint32_t)unlocked << 24;
	return i2c_write(h, &ec_params, (uint8_t *)&cmd, 4);
}

static int
require_salomon(dc_handle *h)
{
	uint8_t t;
	if (ec_read(h, EC_CMD_GET_DOCK_TYPE, 1, &t))
		return -1;
	if (t != DOCK_BASE_TYPE_SALOMON)
		return fail(h, "dock type 0x%02x is not a WD19 (Salomon)", t);
	return 0;
}

/* ---- MST ---- */

static int
mst_read_reg(dc_handle *h, uint32_t addr, size_t len, uint8_t *out)
{
	if (len > 32)
		return fail(h, "register read too long");
	if (i2c_write(h, &mst_params, (uint8_t *)&addr, 4))
		return -1;
	return i2c_read(h, &mst_params, 0, len, out);
}

static int
mst_write_reg(dc_handle *h, uint32_t addr, const uint8_t *data, size_t len)
{
	uint8_t buf[132];
	if (len + 4 > sizeof(buf))
		return fail(h, "register write too long");
	memcpy(buf, &addr, 4);
	memcpy(buf + 4, data, len);
	return i2c_write(h, &mst_params, buf, len + 4);
}

static int mst_enable_rc(dc_handle *h);

static int
mst_trigger_rc(dc_handle *h)
{
	uint32_t tmp = MST_TRIGGER_WRITE;
	uint8_t r[4];
	int status = -1;

	if (mst_write_reg(h, PANAMERA_MST_RC_TRIGGER_ADDR, (uint8_t *)&tmp, 4))
		return -1;
	for (int i = 0; i < 1000; i++) {
		if (mst_read_reg(h, PANAMERA_MST_RC_COMMAND_ADDR, 4, r))
			return -1;
		if ((r[2] & 0x80) == 0) {
			status = r[3];
			break;
		}
		usleep(2000);
	}
	if (status == 4)
		return mst_enable_rc(h);
	if (status != 0)
		return fail(h, "MST RC command failed (status %d)", status);
	return 0;
}

static int
mst_rc_command(dc_handle *h, uint8_t cmd, uint32_t length, uint32_t offset, const uint8_t *data)
{
	uint8_t buf[16 + 32] = {0};
	size_t bufsz = data == NULL ? 12 : length + 16;
	uint32_t w = (uint32_t)(cmd | 0x80) << 16;

	if (data != NULL && length > 32)
		return fail(h, "RC payload too long");
	memcpy(buf, &w, 4);
	memcpy(buf + 4, &offset, 4);
	memcpy(buf + 8, &length, 4);
	if (data != NULL)
		memcpy(buf + 16, data, length);
	if (mst_write_reg(h, PANAMERA_MST_RC_COMMAND_ADDR, buf, bufsz))
		return -1;
	return mst_trigger_rc(h);
}

static int
mst_enable_rc(dc_handle *h)
{
	if (mst_rc_command(h, MST_CMD_ENABLE_RC, 5, 0, (const uint8_t *)"PRIUS") != 0) {
		mst_rc_command(h, MST_CMD_DISABLE_RC, 0, 0, NULL);
		if (mst_rc_command(h, MST_CMD_ENABLE_RC, 5, 0, (const uint8_t *)"PRIUS"))
			return fail(h, "could not enable MST remote control");
	}
	h->rc_enabled = 1;
	return 0;
}

static int
mst_begin(dc_handle *h, int need_rc)
{
	if (require_salomon(h))
		return -1;
	if (ec_modify_lock(h, MST_UNLOCK_TARGET, 1))
		return fail(h, "EC refused MST bus access");
	h->unlocked = 1;
	if (need_rc && mst_enable_rc(h))
		return -1;
	return 0;
}

/* Always safe to call; restores the dock to its normal state. */
static void
mst_end(dc_handle *h)
{
	if (h->rc_enabled) {
		mst_rc_command(h, MST_CMD_DISABLE_RC, 0, 0, NULL);
		h->rc_enabled = 0;
	}
	if (h->unlocked) {
		ec_modify_lock(h, MST_UNLOCK_TARGET, 0);
		h->unlocked = 0;
	}
}

static int
rc_read(dc_handle *h, uint8_t cmd, uint32_t addr, uint32_t len, uint8_t *out)
{
	if (mst_rc_command(h, cmd, len, addr, NULL))
		return -1;
	return mst_read_reg(h, PANAMERA_MST_RC_DATA_ADDR, len, out);
}

/* ---- public API ---- */

int
dc_open(dc_handle **out)
{
	IOHIDManagerRef mgr;
	CFDictionaryRef match;
	CFSetRef set;
	CFIndex n;
	int vid = DELL_VID, pid = BRIDGE_PID;
	dc_handle *h = calloc(1, sizeof(*h));

	*out = h;
	if (h == NULL)
		return -1;
	mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid);
	CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
	const void *keys[] = {CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey)};
	const void *vals[] = {v, p};
	match = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks,
				   &kCFTypeDictionaryValueCallBacks);
	IOHIDManagerSetDeviceMatching(mgr, match);
	set = IOHIDManagerCopyDevices(mgr);
	n = set ? CFSetGetCount(set) : 0;
	if (n == 1) {
		CFSetGetValues(set, (const void **)&h->dev);
		CFRetain(h->dev);
	}
	if (set)
		CFRelease(set);
	CFRelease(match);
	CFRelease(v);
	CFRelease(p);
	CFRelease(mgr);
	if (n != 1)
		return fail(h, n == 0 ? "no WD19 dock connected" : "more than one WD19 dock connected");
	if (IOHIDDeviceOpen(h->dev, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
		CFRelease(h->dev);
		h->dev = NULL;
		return fail(h, "cannot open the dock's HID bridge");
	}
	return 0;
}

void
dc_close(dc_handle *h)
{
	if (h == NULL)
		return;
	if (h->dev) {
		mst_end(h);
		IOHIDDeviceClose(h->dev, kIOHIDOptionsTypeNone);
		CFRelease(h->dev);
	}
	free(h);
}

int
dc_dock_info_read(dc_handle *h, dc_dock_info *out)
{
	uint8_t d[EC_DOCK_DATA_SIZE], info[EC_DOCK_INFO_SIZE];
	CmdBuffer c = {0};

	memset(out, 0, sizeof(*out));
	c.cmd = HUB_CMD_READ_DATA;
	c.ext = HUB_EXT_READ_STATUS;
	c.bufferlen = 12;
	if (hid_set(h, (uint8_t *)&c) || hid_get(h, c.data))
		return -1;
	out->hub_major = c.data[10];
	out->hub_minor = c.data[11];

	if (ec_read(h, EC_CMD_GET_DOCK_TYPE, 1, &out->base_type))
		return -1;
	if (ec_read(h, EC_CMD_GET_DOCK_DATA, EC_DOCK_DATA_SIZE, d))
		return -1;
	memcpy(&out->power_supply_watts, d + 2, 2);
	memcpy(&out->module_type, d + 4, 2);
	memcpy(&out->board_id, d + 6, 2);
	memcpy(&out->package_version, d + 12, 4);
	memcpy(out->service_tag, d + 32, 7);
	memcpy(out->marketing_name, d + 39, 64);

	if (ec_read(h, EC_CMD_GET_DOCK_INFO, EC_DOCK_INFO_SIZE, info))
		return -1;
	for (unsigned i = 0; i < info[0] && 3 + (i + 1) * 9 <= EC_DOCK_INFO_SIZE; i++) {
		const uint8_t *e = info + 3 + i * 9;
		if (e[1] == 4 /* MST */) {
			memcpy(out->mst_version, e + 6, 3);
			out->has_mst_version = 1;
		}
	}
	return 0;
}

int
dc_mst_status_read(dc_handle *h, dc_mst_status *out)
{
	int r = -1;

	memset(out, 0, sizeof(*out));
	if (mst_begin(h, 0) == 0 &&
	    mst_read_reg(h, PANAMERA_MST_CORE_MCU_BOOTLOADER_STS, 4, out->bootloader_status) == 0 &&
	    mst_read_reg(h, PANAMERA_MST_CORE_MCU_FW_VERSION, 4, out->fw_version_reg) == 0) {
		const uint8_t *b = out->bootloader_status;
		out->active_bank = ((b[0] & 0x80) || (b[3] & 0x40)) ? 1 : 0;
		out->running_firmware = (b[0] & 0xf0) == 0;
		r = 0;
	}
	mst_end(h);
	return r;
}

int
dc_mst_read_memory(dc_handle *h, uint32_t addr, uint32_t len, uint8_t *out)
{
	int r = mst_begin(h, 1);
	for (uint32_t off = 0; r == 0 && off < len; off += MST_CHUNK) {
		uint32_t n = len - off < MST_CHUNK ? len - off : MST_CHUNK;
		r = rc_read(h, MST_CMD_READ_MEMORY, addr + off, n, out + off);
	}
	mst_end(h);
	return r;
}

int
dc_mst_read_flash(dc_handle *h, uint32_t offset, uint32_t len, uint8_t *out,
		  void (*progress)(uint32_t done, uint32_t total, void *ctx), void *ctx)
{
	int r = mst_begin(h, 1);
	for (uint32_t off = 0; r == 0 && off < len; off += MST_CHUNK) {
		uint32_t n = len - off < MST_CHUNK ? len - off : MST_CHUNK;
		r = rc_read(h, MST_CMD_READ_FLASH, offset + off, n, out + off);
		if (progress && (off & 0x3fff) == 0)
			progress(off, len, ctx);
	}
	if (r == 0 && progress)
		progress(len, len, ctx);
	mst_end(h);
	return r;
}

int
dc_mst_checksum(dc_handle *h, uint32_t start, uint32_t len, uint32_t *sum)
{
	uint8_t b[4];
	int r = mst_begin(h, 1);

	if (r == 0)
		r = mst_rc_command(h, MST_CMD_CHECKSUM, len, start, NULL);
	if (r == 0)
		r = mst_read_reg(h, PANAMERA_MST_RC_DATA_ADDR, 4, b);
	if (r == 0)
		memcpy(sum, b, 4);
	mst_end(h);
	return r;
}

int
dc_mst_read_register(dc_handle *h, uint32_t addr, uint32_t len, uint8_t *out)
{
	int r = mst_begin(h, 0);
	for (uint32_t off = 0; r == 0 && off < len; off += 32) {
		uint32_t n = len - off < 32 ? len - off : 32;
		r = mst_read_reg(h, addr + off, n, out + off);
	}
	mst_end(h);
	return r;
}

int
dc_mst_set_edid_mode(dc_handle *h, uint8_t mode, uint8_t before[4], uint8_t after[4])
{
	uint8_t cur[4], next[4], chk[4];
	int r;

	if (mode > 4)
		return fail(h, "EDID mode %u out of range (0-4)", mode);
	r = mst_begin(h, 1);
	if (r == 0)
		r = rc_read(h, MST_CMD_READ_MEMORY, DC_RAM_EDID_MODE, 4, cur);
	if (r == 0) {
		memcpy(next, cur, 4);
		next[0] = (uint8_t)((cur[0] & 0xf0) | mode);
		if (memcmp(next, cur, 4) != 0)
			r = mst_rc_command(h, MST_CMD_WRITE_MEMORY, 4, DC_RAM_EDID_MODE, next);
	}
	if (r == 0)
		r = rc_read(h, MST_CMD_READ_MEMORY, DC_RAM_EDID_MODE, 4, chk);
	if (r == 0 && memcmp(chk, next, 4) != 0)
		r = fail(h, "EDID mode read-back mismatch");
	if (r == 0 && before)
		memcpy(before, cur, 4);
	if (r == 0 && after)
		memcpy(after, chk, 4);
	mst_end(h);
	return r;
}
