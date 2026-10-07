/*
 * Driver class for the SunSwift SBus HME FastEthernet card (SUNW,hme).
 *
 * Structure follows the other SPARC network driver (SunLe): the SunOS
 * style kernel interfaces (dev_info, map_regs, mb_nbmapalloc, getprop) set
 * the hardware up, and an IOEthernet subclass talks to the network layer.
 * The interrupt handler runs at interrupt level, clears the chip's status
 * and wakes the driver thread, which then does the real work in
 * -interruptOccurred.
 *
 * DMA: one block of kernel memory is mapped into DVMA space; the chip's
 * descriptor rings and the packet buffers live in it (frames are copied
 * to and from netbufs).
 */

#define MACH_USER_API	1

#import <driverkit/generalFuncs.h>
#import <driverkit/IONetbufQueue.h>
#import <driverkit/interruptMsg.h>

#import "SunHme.h"

#import <kernserv/kern_server_types.h>
#import <kernserv/prototypes.h>

/* ---- SunOS style kernel interfaces (no public headers) ---------------- */

extern caddr_t map_regs(caddr_t addr, unsigned int size, int bustype);
extern int getprop(int node, char *name, int defval);
extern caddr_t getlongprop(int node, char *name);
extern void prom_getidprom(char *buf, int len);
extern unsigned long mb_nbmapalloc(void *map, caddr_t va, int len, int flags,
				   int (*waitfunc)(), caddr_t arg);
extern void *dvmamap;
extern void *kernel_map;
extern int kmem_alloc(void *map, vm_offset_t *addr, vm_size_t size);
extern int splimp(void);
extern int splx(int s);

/* struct dev_info and struct dev_reg, by offset */
struct hme_devreg {
    int			bustype;
    caddr_t		addr;
    unsigned int	size;
};
#define DI_NREG(d)	(*(int *)((char *)(d) + 0x10))
#define DI_REG(d)	(*(struct hme_devreg **)((char *)(d) + 0x14))
#define DI_NODEID(d)	(*(int *)((char *)(d) + 0x28))

/* ---- per unit state shared with the interrupt handler ------------------ */

#define HME_MAXUNITS	4

static volatile unsigned char	*hmeRegs[HME_MAXUNITS][HME_NREGS];
static volatile unsigned int	hmeStatus[HME_MAXUNITS];
static int			hmeUnits = 0;

#define RD(u, set, off)	(*(volatile unsigned int *)(hmeRegs[u][set] + (off)))
#define WR(u, set, off, v) \
    (*(volatile unsigned int *)(hmeRegs[u][set] + (off)) = (v))

#define STAT_BITS	(SEB_STAT_RXTOHOST | SEB_STAT_NORXD | \
			 SEB_STAT_HOSTTOTX | SEB_STAT_TXALL)

/*
 * Interrupt handler. Reading the status register acknowledges the
 * interrupt; remember what it said for the thread.
 */
static void
hmeIntr(void *identity, void *state, unsigned int unit)
{
    unsigned int st;

    if (unit >= HME_MAXUNITS || hmeRegs[unit][HME_SEB] == 0)
	return;
    st = RD(unit, HME_SEB, SEB_STAT) & STAT_BITS;
    if (st) {
	hmeStatus[unit] |= st;
	IOSendInterrupt(identity, state, IO_DEVICE_INTERRUPT_MSG);
    }
}

/* ---- MII (the internal PHY, through the MIF frame register) ------------ */

static unsigned int
hmeMiiRead(int u, int reg)
{
    int i;
    unsigned int v;

    WR(u, HME_MIF, MIF_FRAME, MIF_FO_START | MIF_FO_READ |
       MIF_FO_PHY(PHY_INTERNAL) | MIF_FO_REG(reg) | MIF_FO_TA);
    for (i = 0; i < 1000; i++) {
	v = RD(u, HME_MIF, MIF_FRAME);
	if (v & MIF_FO_TALSB)
	    return v & 0xffff;
	IODelay(10);
    }
    return 0xffff;
}

static void
hmeMiiWrite(int u, int reg, unsigned int data)
{
    int i;

    WR(u, HME_MIF, MIF_FRAME, MIF_FO_START | MIF_FO_WRITE |
       MIF_FO_PHY(PHY_INTERNAL) | MIF_FO_REG(reg) | MIF_FO_TA |
       (data & 0xffff));
    for (i = 0; i < 1000; i++) {
	if (RD(u, HME_MIF, MIF_FRAME) & MIF_FO_TALSB)
	    return;
	IODelay(10);
    }
}

@implementation SunHme

/*
 * Private methods
 */

- (void)_rxFilter
{
    int u = hmeUnit;
    unsigned int hash = multicastEnabled ? 0xffff : 0;
    unsigned int rxcfg = MAC_RXCFG_HENABLE | 0x200 | MAC_RXCFG_ENABLE;

    if (promiscEnabled)
	rxcfg |= MAC_RXCFG_PMISC;
    WR(u, HME_MAC, MAC_HASH0, hash);
    WR(u, HME_MAC, MAC_HASH1, hash);
    WR(u, HME_MAC, MAC_HASH2, hash);
    WR(u, HME_MAC, MAC_HASH3, hash);
    WR(u, HME_MAC, MAC_RXCFG, rxcfg);
}

/*
 * Reset the chip and bring it up with fresh rings.
 */
- (void)_hmeInit
{
    int u = hmeUnit, i;
    volatile unsigned int *rx = (volatile unsigned int *)(dmaVA + HME_RXRING_OFF);
    volatile unsigned int *tx = (volatile unsigned int *)(dmaVA + HME_TXRING_OFF);
    unsigned char *a = (unsigned char *)&myAddress;

    WR(u, HME_SEB, SEB_IMASK, 0xffffffff);
    WR(u, HME_SEB, SEB_RESET, SEB_RESET_ETX | SEB_RESET_ERX);
    for (i = 0; i < 100 && RD(u, HME_SEB, SEB_RESET); i++)
	IODelay(10);

    /* PHY: reset it, then let it autonegotiate */
    hmeMiiWrite(u, MII_BMCR, BMCR_RESET);
    for (i = 0; i < 100 && (hmeMiiRead(u, MII_BMCR) & BMCR_RESET); i++)
	IODelay(100);
    hmeMiiWrite(u, MII_BMCR, BMCR_AUTONEG | BMCR_RESTART_AN);

    /* descriptor rings */
    for (i = 0; i < HME_NRX; i++) {
	rx[2 * i + 1] = dmaDVMA + HME_RXBUF_OFF + i * HME_BUFSZ;
	rx[2 * i] = XD_OWN | (HME_RXLEN << XD_RXLENSHIFT);
    }
    for (i = 0; i < HME_NTX; i++) {
	tx[2 * i + 1] = dmaDVMA + HME_TXBUF_OFF + i * HME_BUFSZ;
	tx[2 * i] = 0;
    }
    rxCons = txProd = txCons = 0;

    /* MAC */
    WR(u, HME_MAC, MAC_XIFCFG, 0);
    WR(u, HME_MAC, MAC_JSIZE, 4);
    WR(u, HME_MAC, MAC_IPGAP1, 8);
    WR(u, HME_MAC, MAC_IPGAP2, 4);
    WR(u, HME_MAC, MAC_RANDSEED, (a[5] << 8) | a[4]);
    WR(u, HME_MAC, MAC_ADDR2, (a[4] << 8) | a[5]);
    WR(u, HME_MAC, MAC_ADDR1, (a[2] << 8) | a[3]);
    WR(u, HME_MAC, MAC_ADDR0, (a[0] << 8) | a[1]);

    /* DMA engines */
    WR(u, HME_SEB, SEB_CFG, 5);
    WR(u, HME_ETX, ETX_RING, dmaDVMA + HME_TXRING_OFF);
    WR(u, HME_ETX, ETX_RSIZE, (HME_NTX / 16) - 1);
    WR(u, HME_ETX, ETX_CFG, ETX_CFG_DMAENABLE);
    WR(u, HME_ERX, ERX_RING, dmaDVMA + HME_RXRING_OFF);
    WR(u, HME_ERX, ERX_CFG, ERX_CFG_DMAENABLE |
       (HME_RXOFF << ERX_CFG_OFFSET_SHIFT) | ERX_CFG_RING32);

    /* go */
    WR(u, HME_MAC, MAC_TXCFG, 0x400);
    WR(u, HME_MAC, MAC_XIFCFG, 1);
    [self _rxFilter];
    WR(u, HME_MAC, MAC_TXCFG, 0x400 | MAC_TXCFG_ENABLE);

    (void)RD(u, HME_SEB, SEB_STAT);		/* clear stale status */
    hmeStatus[u] = 0;
}

/*
 * Hand finished receive descriptors up to the network layer.
 */
- (void)_rxRun
{
    volatile unsigned int *rx = (volatile unsigned int *)(dmaVA + HME_RXRING_OFF);
    unsigned int flags, len;
    netbuf_t pkt;

    for (;;) {
	flags = rx[2 * rxCons];
	if (flags & XD_OWN)
	    break;
	len = (flags & XD_RXLENMSK) >> XD_RXLENSHIFT;
	if (len >= 14 && len <= HME_RXLEN && (pkt = nb_alloc(len)) != 0) {
	    bcopy((void *)(dmaVA + HME_RXBUF_OFF + rxCons * HME_BUFSZ +
			   HME_RXOFF), nb_map(pkt), len);
	    if (!promiscEnabled &&
		[super isUnwantedMulticastPacket:(ether_header_t *)nb_map(pkt)])
		nb_free(pkt);
	    else
		[network handleInputPacket:pkt extra:0];
	} else {
	    [network incrementInputErrors];
	}
	rx[2 * rxCons] = XD_OWN | (HME_RXLEN << XD_RXLENSHIFT);
	rxCons = (rxCons + 1) % HME_NRX;
    }
}

/*
 * Reclaim transmit descriptors the chip has finished with.
 */
- (void)_txReclaim
{
    volatile unsigned int *tx = (volatile unsigned int *)(dmaVA + HME_TXRING_OFF);

    while (txCons != txProd) {
	if (tx[2 * txCons] & XD_OWN)
	    break;
	[network incrementOutputPackets];
	txCons = (txCons + 1) % HME_NTX;
    }
}

/*
 * Public Factory Methods
 */

+ (BOOL)probe:(IODeviceDescription *)devDesc
{
    SunHme	*dev = [self alloc];

    if (dev == nil)
	return NO;
    return [dev initFromDeviceDescription:devDesc] != nil;
}

/*
 * Public Instance Methods
 */

- initFromDeviceDescription:(IODeviceDescription *)devDesc
{
    IOSPARCDeviceDescription *dd = (IOSPARCDeviceDescription *)devDesc;
    char		*di;
    struct hme_devreg	*reg;
    caddr_t		mac;
    char		idprom[0x20];
    int			i;

    if ([super initFromDeviceDescription:devDesc] == nil)
	return nil;

    if (hmeUnits >= HME_MAXUNITS) {
	IOLog("SunHme: too many units\n");
	return [self free];
    }
    hmeUnit = hmeUnits;

    di = (char *)[dd getDeviceInfo];
    if (di == NULL || DI_NREG(di) < HME_NREGS) {
	IOLog("SunHme: bad register specification (%d sets)\n",
	      di ? DI_NREG(di) : 0);
	return [self free];
    }

    /* the five register sets */
    reg = DI_REG(di);
    for (i = 0; i < HME_NREGS; i++) {
	hmeRegs[hmeUnit][i] = (volatile unsigned char *)
	    map_regs(reg[i].addr, reg[i].size, reg[i].bustype);
	if (hmeRegs[hmeUnit][i] == NULL) {
	    IOLog("SunHme: unable to map register set %d\n", i);
	    return [self free];
	}
    }

    /* station address: the card's own, else the machine's */
    mac = getlongprop(DI_NODEID(di), "local-mac-address");
    if (mac != NULL) {
	bcopy(mac, &myAddress, 6);
    } else {
	prom_getidprom(idprom, sizeof(idprom));
	bcopy(&idprom[2], &myAddress, 6);
    }

    /* rings and buffers, visible to the chip through the IOMMU */
    if (kmem_alloc(kernel_map, &dmaVA, HME_DMASIZE) != 0) {
	IOLog("SunHme: kmem_alloc(%d) failed\n", HME_DMASIZE);
	return [self free];
    }
    bzero((void *)dmaVA, HME_DMASIZE);
    dmaDVMA = mb_nbmapalloc(dvmamap, (caddr_t)dmaVA, HME_DMASIZE, 0x40, 0, 0);
    if (dmaDVMA == 0) {
	IOLog("SunHme: mb_nbmapalloc failed\n");
	return [self free];
    }

    hmeUnits++;

    /*
     * Reset the chip, but don't enable yet. We get -resetAndEnable:YES as
     * a side effect of attaching to the network.
     */
    [self resetAndEnable:NO];

    IOLog("hme%d: SunSwift SBus HME, ethernet address %x:%x:%x:%x:%x:%x\n",
	  hmeUnit,
	  ((unsigned char *)&myAddress)[0], ((unsigned char *)&myAddress)[1],
	  ((unsigned char *)&myAddress)[2], ((unsigned char *)&myAddress)[3],
	  ((unsigned char *)&myAddress)[4], ((unsigned char *)&myAddress)[5]);

    network = [super attachToNetworkWithAddress:myAddress];
    return self;
}

- free
{
    int u = hmeUnit;

    if (hmeRegs[u][HME_SEB]) {
	WR(u, HME_SEB, SEB_IMASK, 0xffffffff);
	WR(u, HME_SEB, SEB_RESET, SEB_RESET_ETX | SEB_RESET_ERX);
    }
    /* the DVMA block is not returned: this driver is wired down */
    return [super free];
}

- (BOOL)getHandler:(IOInterruptHandler *)handler
	     level:(unsigned int *)ipl
	  argument:(unsigned int *)arg
      forInterrupt:(unsigned int)localInterrupt
{
    *handler = hmeIntr;
    *ipl = 3;
    *arg = hmeUnit;
    return YES;
}

- (IOReturn)enableAllInterrupts
{
    WR(hmeUnit, HME_SEB, SEB_IMASK, ~STAT_BITS);
    return [super enableAllInterrupts];
}

- (void)disableAllInterrupts
{
    WR(hmeUnit, HME_SEB, SEB_IMASK, 0xffffffff);
    [super disableAllInterrupts];
}

- (BOOL)resetAndEnable:(BOOL)enable
{
    [self disableAllInterrupts];
    [self _hmeInit];

    if (enable && [self enableAllInterrupts] != IO_R_SUCCESS) {
	[self setRunning:NO];
	return NO;
    }
    [self setRunning:enable];
    return YES;
}

- (void)timeoutOccurred
{
    if ([self isRunning])
	[self resetAndEnable:YES];
}

/*
 * Called by our IOThread when it receives the message the interrupt
 * handler sent.
 */
- (void)interruptOccurred
{
    int s;

    s = splimp();
    hmeStatus[hmeUnit] = 0;
    splx(s);

    [self _txReclaim];
    [self _rxRun];
}

- (BOOL)enablePromiscuousMode
{
    promiscEnabled = YES;
    [self _rxFilter];
    return YES;
}

- (void)disablePromiscuousMode
{
    promiscEnabled = NO;
    [self _rxFilter];
}

- (BOOL)enableMulticastMode
{
    multicastEnabled = YES;
    [self _rxFilter];
    return YES;
}

- (void)disableMulticastMode
{
    multicastEnabled = NO;
    [self _rxFilter];
}

/*
 * The hash filter is simply opened up completely in multicast mode and
 * the superclass drops what the stack didn't ask for.
 */
- (void)addMulticastAddress:(enet_addr_t *)addr
{
}

- (void)removeMulticastAddress:(enet_addr_t *)addr
{
}

- (void)transmit:(netbuf_t)pkt
{
    volatile unsigned int *tx = (volatile unsigned int *)(dmaVA + HME_TXRING_OFF);
    unsigned int len = nb_size(pkt);
    unsigned int next = (txProd + 1) % HME_NTX;

    [self _txReclaim];
    if (next == txCons || len > HME_BUFSZ) {
	/* ring full: drop it, the higher levels retransmit */
	nb_free(pkt);
	[network incrementOutputErrors];
	return;
    }

    bcopy(nb_map(pkt), (void *)(dmaVA + HME_TXBUF_OFF + txProd * HME_BUFSZ),
	  len);
    nb_free(pkt);

    tx[2 * txProd + 1] = dmaDVMA + HME_TXBUF_OFF + txProd * HME_BUFSZ;
    tx[2 * txProd] = XD_OWN | XD_SOP | XD_EOP | (len & XD_TXLENMSK);
    txProd = next;

    WR(hmeUnit, HME_ETX, ETX_PENDING, 1);	/* wake the transmitter */
}

@end
