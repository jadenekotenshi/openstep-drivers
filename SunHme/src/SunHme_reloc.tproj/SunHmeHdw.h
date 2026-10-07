/*
 * SunHme -- register layout of the HME ("Happy Meal") FastEthernet chip as
 * found on the SunSwift SBus card. All registers are 32 bits wide and, on
 * SBus, big endian like the CPU, so plain loads and stores are enough.
 */

/* the five register sets, as separate "reg" entries of the PROM node */
#define HME_SEB		0
#define HME_ETX		1
#define HME_ERX		2
#define HME_MAC		3
#define HME_MIF		4
#define HME_NREGS	5

/* SEB: global registers */
#define SEB_RESET	0x000
#define  SEB_RESET_ETX	0x1
#define  SEB_RESET_ERX	0x2
#define SEB_CFG		0x004
#define SEB_STAT	0x100		/* reading clears it */
#define  SEB_STAT_RXTOHOST	0x00010000
#define  SEB_STAT_NORXD		0x00020000
#define  SEB_STAT_MIFIRQ	0x00800000
#define  SEB_STAT_HOSTTOTX	0x01000000
#define  SEB_STAT_TXALL		0x02000000
#define SEB_IMASK	0x104		/* a 1 masks the interrupt */

/* ETX: transmit DMA */
#define ETX_PENDING	0x000
#define ETX_CFG		0x004
#define  ETX_CFG_DMAENABLE	0x1
#define ETX_RING	0x008
#define ETX_RSIZE	0x02c		/* (entries / 16) - 1 */

/* ERX: receive DMA */
#define ERX_CFG		0x000
#define  ERX_CFG_DMAENABLE	0x00000001
#define  ERX_CFG_OFFSET_SHIFT	3
#define  ERX_CFG_RING32		0x000
#define ERX_RING	0x004

/* MAC */
#define MAC_XIFCFG	0x000
#define MAC_TXCFG	0x20c
#define  MAC_TXCFG_ENABLE	0x1
#define MAC_IPGAP1	0x210
#define MAC_IPGAP2	0x214
#define MAC_JSIZE	0x22c
#define MAC_RANDSEED	0x250
#define MAC_RXCFG	0x30c
#define  MAC_RXCFG_ENABLE	0x00000001
#define  MAC_RXCFG_PMISC	0x00000040
#define  MAC_RXCFG_HENABLE	0x00000800
#define MAC_ADDR2	0x318		/* bytes 4,5 */
#define MAC_ADDR1	0x31c		/* bytes 2,3 */
#define MAC_ADDR0	0x320		/* bytes 0,1 */
#define MAC_HASH3	0x340
#define MAC_HASH2	0x344
#define MAC_HASH1	0x348
#define MAC_HASH0	0x34c

/* MIF: PHY management */
#define MIF_FRAME	0x00c
#define  MIF_FO_START		0x40000000
#define  MIF_FO_WRITE		0x10000000
#define  MIF_FO_READ		0x20000000
#define  MIF_FO_PHY(p)		((p) << 23)
#define  MIF_FO_REG(r)		((r) << 18)
#define  MIF_FO_TA		0x00020000
#define  MIF_FO_TALSB		0x00010000
#define MIF_CFG		0x010
#define MIF_IMASK	0x014
#define MIF_STAT	0x018

#define PHY_INTERNAL	1

/* MII registers */
#define MII_BMCR	0
#define  BMCR_RESET		0x8000
#define  BMCR_AUTONEG		0x1000
#define  BMCR_RESTART_AN	0x0200
#define MII_BMSR	1

/* descriptors (two words: flags, DVMA address) */
#define XD_OWN		0x80000000
#define XD_SOP		0x40000000	/* tx */
#define XD_EOP		0x20000000	/* tx */
#define XD_TXLENMSK	0x00001fff
#define XD_RXLENMSK	0x3fff0000
#define XD_RXLENSHIFT	16

/* ring and buffer layout inside the DVMA block */
#define HME_NRX		32
#define HME_NTX		16
#define HME_BUFSZ	1664		/* 1536 + the 2 byte receive offset */
#define HME_RXLEN	1536
#define HME_RXOFF	2
#define HME_RXRING_OFF	0x0000
#define HME_TXRING_OFF	0x0100
#define HME_RXBUF_OFF	0x1000
#define HME_TXBUF_OFF	(HME_RXBUF_OFF + HME_NRX * HME_BUFSZ)
#define HME_DMASIZE	0x20000
