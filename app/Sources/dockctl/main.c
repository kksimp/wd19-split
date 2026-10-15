/*
 * dockctl - command-line front end for DockCore (Dell WD19 / VMM5331).
 * Everything is read-only except `mst-poke`, which can only set the hub's
 * RAM EDID mode nibble (0x1740). A dock power-cycle restores the flash value.
 */

#include "DockCore.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static dc_handle *g_h;

static void
die(const char *what)
{
	fprintf(stderr, "error: %s: %s\n", what, dc_last_error(g_h));
	exit(1);
}

static void
cleanup(void)
{
	dc_close(g_h);
	g_h = NULL;
}

static void
on_signal(int sig)
{
	fprintf(stderr, "\ninterrupted (signal %d), restoring dock state\n", sig);
	cleanup();
	_exit(130);
}

static void
hexdump(uint32_t base, const uint8_t *b, size_t n)
{
	for (size_t i = 0; i < n; i += 16) {
		printf("%08x ", base + (uint32_t)i);
		for (size_t j = i; j < i + 16 && j < n; j++)
			printf(" %02x", b[j]);
		printf("\n");
	}
}

static void
progress(uint32_t done, uint32_t total, void *ctx)
{
	(void)ctx;
	fprintf(stderr, "\r  0x%06x / 0x%06x", done, total);
	if (done == total)
		fprintf(stderr, " done\n");
}

static uint32_t
num(const char *s)
{
	return (uint32_t)strtoul(s, NULL, 0);
}

static void
usage(void)
{
	fprintf(stderr,
		"usage: dockctl <command>\n"
		"  info                         dock name, service tag, component versions\n"
		"  mst-status                   MST bootloader status, active bank, fw version\n"
		"  mst-dump <file> [start len]  read MST SPI flash (default all 0x80000 bytes)\n"
		"  mst-checksum <start> <len>   have the hub byte-sum a flash range\n"
		"  mst-mem <addr> [len]         read MST MCU memory\n"
		"  mst-reg <addr> [len]         read MST registers directly over I2C\n"
		"  mst-poke 0x1740 <0-4>        WRITE hub RAM EDID mode (2 = split, 3 = Dell default)\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	if (argc < 2)
		usage();
	if (dc_open(&g_h))
		die("open");
	atexit(cleanup);
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	const char *cmd = argv[1];
	if (strcmp(cmd, "info") == 0) {
		dc_dock_info i;
		if (dc_dock_info_read(g_h, &i))
			die("info");
		printf("bridge hub version: %02x.%02x\n", i.hub_major, i.hub_minor);
		printf("dock base type: 0x%02x\nmarketing name: %s\nservice tag: %s\n", i.base_type,
		       i.marketing_name, i.service_tag);
		printf("module type: %u, board id: %u, power supply: %uW\n", i.module_type, i.board_id,
		       i.power_supply_watts);
		printf("dock fw package: %08x\n", i.package_version);
		if (i.has_mst_version)
			printf("MST version: %02x.%02x.%02x\n", i.mst_version[0], i.mst_version[1],
			       i.mst_version[2]);
	} else if (strcmp(cmd, "mst-status") == 0) {
		dc_mst_status s;
		if (dc_mst_status_read(g_h, &s))
			die("mst-status");
		printf("bootloader status: %02x %02x %02x %02x\n", s.bootloader_status[0],
		       s.bootloader_status[1], s.bootloader_status[2], s.bootloader_status[3]);
		printf("running in %s, active bank %d\n", s.running_firmware ? "firmware" : "bootloader",
		       s.active_bank);
		printf("fw version register: %02x %02x %02x %02x\n", s.fw_version_reg[0],
		       s.fw_version_reg[1], s.fw_version_reg[2], s.fw_version_reg[3]);
	} else if (strcmp(cmd, "mst-dump") == 0 && argc >= 3) {
		uint32_t start = argc >= 4 ? num(argv[3]) : 0;
		uint32_t len = argc >= 5 ? num(argv[4]) : 0x80000;
		uint8_t *buf = malloc(len);
		FILE *f;
		if (buf == NULL || dc_mst_read_flash(g_h, start, len, buf, progress, NULL))
			die("mst-dump");
		f = fopen(argv[2], "wb");
		if (f == NULL || fwrite(buf, 1, len, f) != len) {
			fprintf(stderr, "error: cannot write %s\n", argv[2]);
			return 1;
		}
		fclose(f);
		free(buf);
		printf("wrote %u bytes from flash 0x%x to %s\n", len, start, argv[2]);
	} else if (strcmp(cmd, "mst-checksum") == 0 && argc >= 4) {
		uint32_t sum;
		if (dc_mst_checksum(g_h, num(argv[2]), num(argv[3]), &sum))
			die("mst-checksum");
		printf("hub byte-sum of flash 0x%x+0x%x: 0x%08x\n", num(argv[2]), num(argv[3]), sum);
	} else if ((strcmp(cmd, "mst-mem") == 0 || strcmp(cmd, "mst-reg") == 0) && argc >= 3) {
		uint32_t addr = num(argv[2]), len = argc >= 4 ? num(argv[3]) : 16;
		uint8_t *buf = calloc(1, len);
		int r = cmd[4] == 'm' ? dc_mst_read_memory(g_h, addr, len, buf)
				      : dc_mst_read_register(g_h, addr, len, buf);
		if (buf == NULL || r)
			die(cmd);
		hexdump(addr, buf, len);
		free(buf);
	} else if (strcmp(cmd, "mst-poke") == 0 && argc >= 4) {
		uint8_t before[4], after[4];
		if (num(argv[2]) != DC_RAM_EDID_MODE) {
			fprintf(stderr, "error: only 0x%x is allowlisted\n", DC_RAM_EDID_MODE);
			return 1;
		}
		if (dc_mst_set_edid_mode(g_h, (uint8_t)num(argv[3]), before, after))
			die("mst-poke");
		printf("0x%x: %02x -> %02x\n", DC_RAM_EDID_MODE, before[0], after[0]);
	} else {
		usage();
	}
	return 0;
}
