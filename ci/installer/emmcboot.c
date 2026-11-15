/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * emmcboot: show or set the eMMC boot configuration (EXT_CSD
 * PARTITION_CONFIG) through mmcsd(4)'s MMC_IOC_CMD ioctl.
 *
 *	emmcboot [-s value] /dev/mmcsd0
 *
 * Without -s it prints PARTITION_CONFIG, BOOT_BUS_CONDITIONS and the boot
 * write protection status.  With -s it writes PARTITION_CONFIG with CMD6.
 *
 * Use it on the user area device (/dev/mmcsd0), right after an access to
 * that device: mmcsd keeps its own copy of PARTITION_CONFIG and writes it
 * back whenever it switches partitions, so detach and attach the bus
 * afterwards before touching boot0, boot1 or the RPMB again.
 *
 * The BPI-R3 boot ROM wants boot0 enabled with boot acknowledge:
 * 0x48 (BOOT_ACK, boot partition 1, access to the user area).
 */

#include <sys/types.h>
#include <sys/ioctl.h>

#include <dev/mmc/mmcreg.h>
#include <dev/mmc/mmc_ioctl.h>

#include <err.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define	EXT_CSD_BOOT_BUS_CONDITIONS	177

static void
read_ext_csd(int fd, uint8_t *ext_csd)
{
	struct mmc_ioc_cmd mic;

	memset(&mic, 0, sizeof(mic));
	mic.opcode = MMC_SEND_EXT_CSD;
	mic.flags = MMC_RSP_R1 | MMC_CMD_ADTC;
	mic.blksz = MMC_EXTCSD_SIZE;
	mic.blocks = 1;
	mmc_ioc_cmd_set_data(mic, ext_csd);
	if (ioctl(fd, MMC_IOC_CMD, &mic) != 0)
		err(1, "SEND_EXT_CSD");
}

static void
write_part_config(int fd, uint8_t value)
{
	struct mmc_ioc_cmd mic;

	memset(&mic, 0, sizeof(mic));
	mic.write_flag = 1;
	mic.opcode = MMC_SWITCH_FUNC;
	mic.arg = (MMC_SWITCH_FUNC_WR << 24) | (EXT_CSD_PART_CONFIG << 16) |
	    (value << 8) | EXT_CSD_CMD_SET_NORMAL;
	mic.flags = MMC_RSP_R1B | MMC_CMD_AC;
	if (ioctl(fd, MMC_IOC_CMD, &mic) != 0)
		err(1, "SWITCH PARTITION_CONFIG");
}

static void
usage(void)
{
	fprintf(stderr, "usage: emmcboot [-s value] device\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	uint8_t ext_csd[MMC_EXTCSD_SIZE];
	unsigned long value;
	char *end;
	int ch, fd, set;

	set = 0;
	value = 0;
	while ((ch = getopt(argc, argv, "s:")) != -1) {
		switch (ch) {
		case 's':
			value = strtoul(optarg, &end, 0);
			if (*end != '\0' || value > 0xff)
				errx(2, "bad value: %s", optarg);
			set = 1;
			break;
		default:
			usage();
		}
	}
	argc -= optind;
	argv += optind;
	if (argc != 1)
		usage();

	if ((fd = open(argv[0], set ? O_RDWR : O_RDONLY)) < 0)
		err(1, "%s", argv[0]);
	if (set) {
		write_part_config(fd, (uint8_t)value);
		printf("PARTITION_CONFIG set to 0x%02lx\n", value);
	} else {
		read_ext_csd(fd, ext_csd);
		printf("PARTITION_CONFIG 0x%02x\n", ext_csd[EXT_CSD_PART_CONFIG]);
		printf("BOOT_BUS_CONDITIONS 0x%02x\n",
		    ext_csd[EXT_CSD_BOOT_BUS_CONDITIONS]);
		printf("BOOT_WP_STATUS 0x%02x\n", ext_csd[EXT_CSD_BOOT_WP_STATUS]);
		printf("EXT_CSD_REV %u\n", ext_csd[EXT_CSD_REV]);
	}
	close(fd);
	return (0);
}
