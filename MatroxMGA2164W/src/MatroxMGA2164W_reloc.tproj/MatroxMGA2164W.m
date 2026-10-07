/*
 * MatroxMGA2164W -- Matrox Millennium II (MGA-2164W + TVP3026) display
 * driver for OPENSTEP 4.2 / DriverKit.
 *
 * Register sequences and PLL arithmetic follow the X.Org xf86-video-mga
 * driver (see NOTICE).
 */
#import <string.h>
#import <bsd/dev/ev_types.h>
#import <driverkit/generalFuncs.h>
#import <driverkit/i386/ioPorts.h>
#import <driverkit/i386/IOPCIDeviceDescription.h>
#import <driverkit/i386/IOPCIDirectDevice.h>
#import "MatroxMGA2164W.h"
#import "MGAVga.h"

#ifndef EV_SCREEN_MAX_BRIGHTNESS
#define EV_SCREEN_MIN_BRIGHTNESS	0
#define EV_SCREEN_MAX_BRIGHTNESS	64
#define EV_SCALE_BRIGHTNESS(level, data) \
	(((data) * (level)) / EV_SCREEN_MAX_BRIGHTNESS)
#endif

#define PCI_OPTION_REG		0x40
#define OPTION_MASK		0xFFEFFEFF

#define CRTCEXT_INDEX		0x3DE
#define CRTCEXT_DATA		0x3DF

/* TVP3026 registers, offsets within the control aperture */
#define RAMDAC_OFFSET		0x3C00
#define TVP_INDEX		0x00
#define TVP_WADR_PAL		0x00
#define TVP_COL_PAL		0x01
#define TVP_PIX_RD_MSK		0x02
#define TVP_DATA		0x0A

#define TVP_SILICON_REV		0x01
#define TVP_CLK_SEL		0x1A
#define TVP_PLL_ADDR		0x2C
#define TVP_PIX_CLK_DATA	0x2D
#define TVP_LOAD_CLK_DATA	0x2F
#define TVP_MCLK_CTL		0x39

#define TI_MIN_VCO_FREQ		110000
#define TI_MAX_VCO_FREQ		220000
#define TI_REF_FREQ_8		114544	/* 8 * 14318.18 kHz */

static const unsigned char MGADACregs[MGA_DACREGS] = {
    0x0F, 0x18, 0x19, 0x1A, 0x1C, 0x1D, 0x1E, 0x2A, 0x2B, 0x30, 0x31,
    0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x06
};
static const unsigned char DACbpp8[MGA_DACREGS] = {
    0x06, 0x80, 0x4B, 0x25, 0x00, 0x00, 0x0C, 0x00, 0x1E, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00
};
static const unsigned char DACbpp16[MGA_DACREGS] = {
    0x07, 0x45, 0x53, 0x15, 0x00, 0x00, 0x2C, 0x00, 0x1E, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x10, 0x00, 0x00, 0x00
};
static const unsigned char DACbpp32[MGA_DACREGS] = {
    0x07, 0x46, 0x5B, 0x05, 0x00, 0x00, 0x2C, 0x00, 0x1E, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x10, 0x00, 0x00, 0x00
};

#define DAC_W(c, idx, val) do { \
	(c)[RAMDAC_OFFSET + TVP_INDEX] = (idx); \
	(c)[RAMDAC_OFFSET + TVP_DATA] = (val); \
    } while (0)
#define DAC_R(c, idx, var) do { \
	(c)[RAMDAC_OFFSET + TVP_INDEX] = (idx); \
	(var) = (c)[RAMDAC_OFFSET + TVP_DATA]; \
    } while (0)

static unsigned long
barSize(id self, id devDesc, int reg, unsigned long cmd)
{
    unsigned long orig, probe;

    [self setPCIConfigData:(cmd & ~0x2) atRegister:0x04
	withDeviceDescription:devDesc];
    [self getPCIConfigData:&orig atRegister:reg withDeviceDescription:devDesc];
    [self setPCIConfigData:0xffffffff atRegister:reg
	withDeviceDescription:devDesc];
    [self getPCIConfigData:&probe atRegister:reg withDeviceDescription:devDesc];
    [self setPCIConfigData:orig atRegister:reg withDeviceDescription:devDesc];
    [self setPCIConfigData:cmd atRegister:0x04 withDeviceDescription:devDesc];
    return ~(probe & ~0xf) + 1;
}

/* TVP3026 PLL: choose n, m, p for f_out (kHz); returns the actual output.
 * Integer version of MGATi3026CalcClock (the kernel must not use the FPU). */
static unsigned int
calcClock(unsigned int fout, unsigned int fmax, int *m, int *n, int *p)
{
    unsigned int fvco, inc, calc, err = 0xFFFFFFFF, fpll;
    int bestm = 0, bestn = 0, k;

    if (fout < TI_MIN_VCO_FREQ / 8)
	fout = TI_MIN_VCO_FREQ / 8;
    if (fout > fmax)
	fout = fmax;
    fvco = fout;
    for (*p = 0; *p < 3 && fvco < TI_MIN_VCO_FREQ; (*p)++)
	fvco *= 2;
    /* 12-bit fixed point: inc = fvco / (8 * refclk) */
    inc = (fvco * 4096) / TI_REF_FREQ_8;
    calc = inc * 3;
    for (k = 3; k <= 25; k++, calc += inc) {
	unsigned int frac;

	if (calc < 3 * 4096 || calc > 64 * 4096)
	    continue;
	frac = calc & 4095;
	if (frac < err) {
	    err = frac;
	    bestm = calc >> 12;
	    bestn = k;
	}
    }
    *m = 65 - bestm;
    *n = 65 - bestn;
    fvco = (TI_REF_FREQ_8 * bestm) / bestn;
    fpll = fvco >> *p;
    return fpll;
}


/* ---- MTRR write combining ------------------------------------------- */

#define MSR_MTRRCAP	0xfe
#define MSR_MTRRDEFTYPE	0x2ff
#define MSR_MTRRBASE(i)	(0x200 + 2 * (i))
#define MSR_MTRRMASK(i)	(0x201 + 2 * (i))

static void
rdmsr(unsigned int msr, unsigned int *lo, unsigned int *hi)
{
    asm volatile("rdmsr" : "=a" (*lo), "=d" (*hi) : "c" (msr));
}

static void
wrmsr(unsigned int msr, unsigned int lo, unsigned int hi)
{
    asm volatile("wrmsr" : : "a" (lo), "d" (hi), "c" (msr));
}

static unsigned int
rdtscLow(void)
{
    unsigned int lo, hi;

    asm volatile("rdtsc" : "=a" (lo), "=d" (hi));
    return lo;
}

static int
cpuHasMTRR(unsigned int *physHi)
{
    unsigned int before, after, a, b, c, d;

    asm volatile("pushfl; pushfl; popl %0; movl %0,%1; xorl $0x200000,%0;"
		 "pushl %0; popfl; pushfl; popl %0; popfl"
		 : "=&r" (after), "=&r" (before));
    if (((before ^ after) & 0x200000) == 0)
	return 0;
    asm volatile("cpuid" : "=a" (a), "=b" (b), "=c" (c), "=d" (d) : "0" (0));
    if (a < 1)
	return 0;
    asm volatile("cpuid" : "=a" (a), "=b" (b), "=c" (c), "=d" (d) : "0" (1));
    if (!(d & (1 << 5)) || !(d & (1 << 12)))	/* MSR, MTRR */
	return 0;
    /* PAE or PSE-36 means 36 physical address bits on P6-class parts */
    *physHi = (d & ((1 << 6) | (1 << 17))) ? 0x0F : 0;
    return 1;
}

/* Run `wrmsr' sequence for one variable MTRR with caches off (Intel SDM
 * 11.11.7.2).  Uniprocessor only; interrupts are off for the duration. */
static void
mtrrProgram(int slot, unsigned int baseLo, unsigned int maskLo,
	    unsigned int physHi, unsigned int defLo, unsigned int defHi)
{
    unsigned int flags, cr0, tmp;

    asm volatile("pushfl; popl %0; cli" : "=r" (flags) : : "memory");
    asm volatile("movl %%cr0,%0" : "=r" (cr0));
    asm volatile("movl %0,%%cr0" : : "r" ((cr0 | 0x40000000) & ~0x20000000)
		 : "memory");
    asm volatile("wbinvd" : : : "memory");
    asm volatile("movl %%cr3,%0; movl %0,%%cr3" : "=r" (tmp) : : "memory");
    wrmsr(MSR_MTRRDEFTYPE, defLo & ~0x800, defHi);
    wrmsr(MSR_MTRRBASE(slot), baseLo, 0);
    wrmsr(MSR_MTRRMASK(slot), maskLo, physHi);
    asm volatile("wbinvd" : : : "memory");
    asm volatile("movl %%cr3,%0; movl %0,%%cr3" : "=r" (tmp) : : "memory");
    wrmsr(MSR_MTRRDEFTYPE, defLo | 0x800, defHi);
    asm volatile("movl %0,%%cr0" : : "r" (cr0) : "memory");
    asm volatile("pushl %0; popfl" : : "r" (flags) : "memory");
}

/* Returns the slot used, or -1. */
static int
mtrrSetWC(unsigned int base, unsigned int size)
{
    unsigned int physHi, capLo, capHi, defLo, defHi, lo, hi, blo, bhi;
    unsigned int mask = ~(size - 1);
    int i, vcnt, slot = -1;

    if (!cpuHasMTRR(&physHi)) {
	IOLog("MatroxMGA2164W: no MTRRs, write combining unavailable\n");
	return -1;
    }
    rdmsr(MSR_MTRRCAP, &capLo, &capHi);
    vcnt = capLo & 0xFF;
    if (!(capLo & 0x400)) {
	IOLog("MatroxMGA2164W: CPU MTRRs lack write-combining\n");
	return -1;
    }
    rdmsr(MSR_MTRRDEFTYPE, &defLo, &defHi);
    if (!(defLo & 0x800)) {
	IOLog("MatroxMGA2164W: MTRRs disabled by firmware\n");
	return -1;
    }
    for (i = 0; i < vcnt; i++) {
	rdmsr(MSR_MTRRMASK(i), &lo, &hi);
	if (!(lo & 0x800)) {
	    if (slot < 0)
		slot = i;
	    continue;
	}
	rdmsr(MSR_MTRRBASE(i), &blo, &bhi);
	if (((base ^ blo) & mask & lo & 0xFFFFF000) == 0) {
	    IOLog("MatroxMGA2164W: framebuffer overlaps MTRR%d "
		  "(base 0x%08x type %d), leaving it alone\n", i,
		  blo & 0xFFFFF000, blo & 0xFF);
	    return -1;
	}
    }
    if (slot < 0) {
	IOLog("MatroxMGA2164W: no free variable MTRR\n");
	return -1;
    }
    mtrrProgram(slot, (base & 0xFFFFF000) | 1, (mask & 0xFFFFF000) | 0x800,
		physHi, defLo, defHi);
    return slot;
}

static void
mtrrClear(int slot)
{
    unsigned int physHi, defLo, defHi;

    if (slot < 0 || !cpuHasMTRR(&physHi))
	return;
    rdmsr(MSR_MTRRDEFTYPE, &defLo, &defHi);
    mtrrProgram(slot, 0, 0, 0, defLo, defHi);
}

/* Cycles to write `bytes' of words at fb[0..]. */
static unsigned int
writeCycles(volatile unsigned int *fb, unsigned int bytes)
{
    unsigned int i, t0, words = bytes / 4;

    t0 = rdtscLow();
    for (i = 0; i < words; i++)
	fb[i] = 0;
    return rdtscLow() - t0;
}


/* ---- TVP3026 hardware cursor ------------------------------------------
 *
 * The event system keeps the 16x16 cursor bitmaps (premultiplied alpha, in
 * the format of the current depth) in the shared state block that
 * IOFrameBufferDisplay keeps in its private `priv' instance variable, and
 * the superclass draws them in software.  We read the same block and load a
 * two-colour-plus-transparent image into the TVP3026's cursor RAM instead.
 * Layout of the block (found by disassembling the superclass):
 *   +0x04 lock       +0x30/32/34/36 screen minx/maxx/miny/maxy (shorts)
 *   +0x38 + 4*frame  hotspot (x low short, y high short)
 *   +0x48 + ...      images: 8 bpp  256 bytes/frame, alpha planes at +0x448
 *                            12/15 bpp 4:4:4:4 RGBA, 512 bytes/frame
 *                            24 bpp 32-bit, 1 KB/frame, alpha in the top byte
 *                            when pixelEncoding starts with 'A' or '-'
 */
#define EV_PRIV_OFFSET		0x1fc
#define EVP_LOCK		0x04
#define EVP_MINX		0x30
#define EVP_MAXX		0x32
#define EVP_MINY		0x34
#define EVP_MAXY		0x36
#define EVP_HOT			0x38
#define EVP_IMAGES		0x48
#define EVP_ALPHA8		0x448

#define TVP_CUR_COL_ADDR	0x04
#define TVP_CUR_COL_DATA	0x05
#define TVP_CUR_RAM		0x0B
#define TVP_CUR_XLOW		0x0C
#define TVP_CUR_XHI		0x0D
#define TVP_CUR_YLOW		0x0E
#define TVP_CUR_YHI		0x0F
#define TVP_CURSOR_CTL		0x06

static unsigned char *
evPriv(id self)
{
    return *(unsigned char **)((char *)self + EV_PRIV_OFFSET);
}

static unsigned int
unpremul(unsigned int c, unsigned int a)
{
    unsigned int v;

    if (a == 0)
	return 0;
    v = (c * 255) / a;
    return v > 255 ? 255 : v;
}

@implementation MatroxMGA2164W

+ (BOOL)probe:deviceDescription
{
    IOPCIConfigSpace cs;
    IORange ranges[2];
    unsigned long cmd;
    IOReturn r;

    if (![self isPCIPresent])
	return NO;
    if ([self getPCIConfigSpace:&cs withDeviceDescription:deviceDescription]
	!= IO_R_SUCCESS)
	return NO;
    cmd = cs.Command;
    ranges[0].start = cs.BaseAddress[0] & ~0xFUL;
    ranges[0].size = barSize(self, deviceDescription, 0x10, cmd);
    ranges[1].start = cs.BaseAddress[1] & ~0xFUL;
    ranges[1].size = barSize(self, deviceDescription, 0x14, cmd);
    if (ranges[0].start == 0 || ranges[1].start == 0 ||
	ranges[0].size < 0x400000 || ranges[1].size < 0x4000) {
	IOLog("MatroxMGA2164W: unexpected BARs 0x%x/0x%x\n",
	      (unsigned int)cs.BaseAddress[0], (unsigned int)cs.BaseAddress[1]);
	return NO;
    }
    r = [deviceDescription setMemoryRangeList:ranges num:2];
    if (r != IO_R_SUCCESS) {
	IOLog("MatroxMGA2164W: setMemoryRangeList failed (%d)\n",
	      (int)r);
	return NO;
    }
    return [super probe:deviceDescription];
}

static int
probeVideoRAM(volatile unsigned int *fb, unsigned int maxBytes)
{
    unsigned int x, size = 1 << 20;
    unsigned int s0, sx;

    s0 = fb[0];
    for (x = 1 << 20; x < maxBytes; x <<= 1) {
	sx = fb[x / 4];
	fb[0] = 0xA5A5C3C3;
	fb[x / 4] = 0x5A5A3C3C;
	if (fb[0] == 0xA5A5C3C3 && fb[x / 4] == 0x5A5A3C3C) {
	    size = x * 2;
	    fb[x / 4] = sx;
	} else {
	    fb[x / 4] = sx;
	    break;
	}
    }
    fb[0] = s0;
    return size;
}

- initFromDeviceDescription:deviceDescription
{
    const IORange *range;
    vm_address_t va;
    IODisplayInfo *di;
    unsigned long opt;
    int k, mode;
    BOOL valid[MGAModeMax];
    const char *s;
    unsigned int memLimit;

    if ([super initFromDeviceDescription:deviceDescription] == nil)
	return [super free];

    mtrrSlot = -1;
    cursorFrame = -1;
    hwCursor = 0;
    range = [deviceDescription memoryRangeList];
    if (range == 0 || [deviceDescription numMemoryRanges] < 2) {
	IOLog("%s: no memory ranges.\n", [self name]);
	return [super free];
    }
    lfbPhys = range[0].start;
    lfbSize = range[0].size;
    ctlPhys = range[1].start;

    if ([self mapMemoryRange:1 to:&va findSpace:YES cache:IO_CacheOff]
	!= IO_R_SUCCESS) {
	IOLog("%s: cannot map control registers.\n", [self name]);
	return [super free];
    }
    ctl = (volatile unsigned char *)va;

    /* Save the BIOS state so that revertToVGAMode can put it back. */
    [self getPCIConfigData:&opt atRegister:PCI_OPTION_REG];
    savedOption = opt;
    for (k = 0; k < 6; k++) {
	outb(CRTCEXT_INDEX, k);
	savedExt[k] = inb(CRTCEXT_DATA);
    }
    for (k = 0; k < MGA_DACREGS; k++)
	DAC_R(ctl, MGADACregs[k], savedDac[k]);
    saved = 1;

    /* Map the framebuffer (uncached for now: the sizing probe writes to it). */
    di = [self displayInfo];
    di->flags = 0;
    s = [[[self deviceDescription] configTable] valueForStringKey:
	 "DisplayCacheMode"];
    if (s != 0) {
	if (strcmp(s, "Off") == 0)
	    di->flags |= IO_DISPLAY_CACHE_OFF;
	else if (strcmp(s, "WriteThrough") == 0)
	    di->flags |= IO_DISPLAY_CACHE_WRITETHROUGH;
	else if (strcmp(s, "CopyBack") == 0)
	    di->flags |= IO_DISPLAY_CACHE_COPYBACK;
	else
	    IOLog("%s: unrecognized DisplayCacheMode `%s'.\n", [self name], s);
    }
    memLimit = lfbSize > 0x1000000 ? 0x1000000 : lfbSize;
    di->frameBuffer = (void *)[self mapFrameBufferAtPhysicalAddress:lfbPhys
				length:memLimit];
    if (di->frameBuffer == 0)
	return [super free];


    vramBytes = probeVideoRAM((volatile unsigned int *)di->frameBuffer,
			      memLimit);
    interleave = vramBytes > (2 << 20);

    if ([self booleanForKey:"WriteCombining" withDefault:YES]) {
	unsigned int cacheMode = di->flags & IO_DISPLAY_CACHE_MASK;
	volatile unsigned int *test = (volatile unsigned int *)
	    ((char *)di->frameBuffer + (vramBytes - (256 << 10)));
	unsigned int before, after;

	if (cacheMode == IO_DISPLAY_CACHE_OFF) {
	    IOLog("%s: DisplayCacheMode is Off; not using write combining.\n",
		  [self name]);
	} else {
	    before = writeCycles(test, 256 << 10);
	    mtrrSlot = mtrrSetWC(lfbPhys, lfbSize);
	    if (mtrrSlot >= 0) {
		after = writeCycles(test, 256 << 10);
		IOLog("%s: write combining on (MTRR%d, 0x%08x + 0x%x); "
		      "256 KB write: %u -> %u cycles\n", [self name], mtrrSlot,
		      lfbPhys, lfbSize, before, after);
	    }
	}
    }

    modeCount = MGABuildModeTable(modeTable, modeData, vramBytes);
    for (k = 0; k < modeCount; k++)
	valid[k] = (modeTable[k].modeUnavailableFlag == 0);
    mode = [self selectMode:modeTable count:modeCount valid:valid];
    if (mode < 0) {
	IOLog("%s: cannot use requested display mode, using default.\n",
	      [self name]);
	mode = MGADefaultMode;
    }
    {
	void *fb = di->frameBuffer;
	unsigned int fl = di->flags;

	*di = modeTable[mode];
	di->frameBuffer = fb;
	di->flags = fl;
    }
    if (di->bitsPerPixel != IO_8BitsPerPixel)
	di->flags |= IO_DISPLAY_NEEDS_SOFTWARE_GAMMA_CORRECTION;
    if (di->bitsPerPixel == IO_8BitsPerPixel)
	di->flags |= IO_DISPLAY_HAS_TRANSFER_TABLE;

    redTransferTable = greenTransferTable = blueTransferTable = 0;
    transferTableCount = 0;
    brightnessLevel = EV_SCREEN_MAX_BRIGHTNESS;
    for (k = 0; k < 256; k++)
	palShadow[k][0] = palShadow[k][1] = palShadow[k][2] = k;
    hwCursor = [self booleanForKey:"HardwareCursor" withDefault:YES];

    IOLog("%s: Matrox Millennium II, %d MB VRAM%s; `%d x %d @ %d Hz'.\n",
	  [self name], vramBytes >> 20, interleave ? " (interleaved)" : "",
	  di->width, di->height, di->refreshRate);
    return self;
}

- (BOOL)booleanForKey:(const char *)key withDefault:(BOOL)def
{
    const char *v = [[[self deviceDescription] configTable]
		     valueForStringKey:key];

    if (v == 0)
	return def;
    if (v[0] == 'Y' || v[0] == 'y')
	return YES;
    if (v[0] == 'N' || v[0] == 'n')
	return NO;
    return def;
}

- free
{
    if (mtrrSlot >= 0) {
	mtrrClear(mtrrSlot);
	mtrrSlot = -1;
    }
    return [super free];
}


/* Convert one cursor frame and load it into the DAC's cursor RAM. */
- (void)loadCursorFrame:(int)frame from:(unsigned char *)p
{
    IODisplayInfo *di = [self displayInfo];
    unsigned char ram[1024];
    unsigned int lr = 0, lg = 0, lb = 0, ln = 0, dr = 0, dg = 0, db = 0, dn = 0;
    int x, y, i, wait;
    unsigned char old;

    memset(ram, 0, sizeof(ram));
    if (frame < 0 || frame > 3)
	frame = 0;
    for (y = 0; y < 16; y++) {
	for (x = 0; x < 16; x++) {
	    unsigned int a, r, g, b, lum;

	    i = y * 16 + x;
	    switch (di->bitsPerPixel) {
	    case IO_8BitsPerPixel: {
		unsigned int d = p[EVP_IMAGES + frame * 256 + i];

		a = p[EVP_ALPHA8 + frame * 256 + i];
		if (di->colorSpace == IO_OneIsWhiteColorSpace) {
		    r = g = b = unpremul(d, a);
		} else {
		    r = palShadow[d][0];
		    g = palShadow[d][1];
		    b = palShadow[d][2];
		}
		break;
	    }
	    case IO_24BitsPerPixel: {
		unsigned int v = *(unsigned int *)(p + EVP_IMAGES + frame * 1024
						   + i * 4);

		if (di->pixelEncoding[0] == 'A' || di->pixelEncoding[0] == '-') {
		    a = v >> 24;
		    r = unpremul((v >> 16) & 0xFF, a);
		    g = unpremul((v >> 8) & 0xFF, a);
		    b = unpremul(v & 0xFF, a);
		} else {
		    a = v & 0xFF;
		    r = unpremul(v >> 24, a);
		    g = unpremul((v >> 16) & 0xFF, a);
		    b = unpremul((v >> 8) & 0xFF, a);
		}
		break;
	    }
	    default: {
		unsigned int v = *(unsigned short *)(p + EVP_IMAGES + frame * 512
						     + i * 2);

		a = (v & 0xF) * 17;
		r = unpremul(((v >> 12) & 0xF) * 17, a);
		g = unpremul(((v >> 8) & 0xF) * 17, a);
		b = unpremul(((v >> 4) & 0xF) * 17, a);
		break;
	    }
	    }
	    if (a < 128)
		continue;
	    lum = (r * 30 + g * 59 + b * 11) / 100;
	    ram[512 + y * 8 + (x >> 3)] |= 0x80 >> (x & 7);	/* opaque */
	    if (lum >= 128) {
		ram[y * 8 + (x >> 3)] |= 0x80 >> (x & 7);	/* foreground */
		lr += r; lg += g; lb += b; ln++;
	    } else {
		dr += r; dg += g; db += b; dn++;
	    }
	}
    }
    if (ln) { lr /= ln; lg /= ln; lb /= ln; } else { lr = lg = lb = 255; }
    if (dn) { dr /= dn; dg /= dn; db /= dn; } else { dr = dg = db = 0; }

    ctl[RAMDAC_OFFSET + TVP_CUR_COL_ADDR] = 1;		/* background */
    ctl[RAMDAC_OFFSET + TVP_CUR_COL_DATA] = dr;
    ctl[RAMDAC_OFFSET + TVP_CUR_COL_DATA] = dg;
    ctl[RAMDAC_OFFSET + TVP_CUR_COL_DATA] = db;
    ctl[RAMDAC_OFFSET + TVP_CUR_COL_ADDR] = 2;		/* foreground */
    ctl[RAMDAC_OFFSET + TVP_CUR_COL_DATA] = lr;
    ctl[RAMDAC_OFFSET + TVP_CUR_COL_DATA] = lg;
    ctl[RAMDAC_OFFSET + TVP_CUR_COL_DATA] = lb;

    DAC_R(ctl, TVP_CURSOR_CTL, old);
    DAC_W(ctl, TVP_CURSOR_CTL, old & 0xF3);	/* cursor RAM address A9,A8 = 0 */
    ctl[RAMDAC_OFFSET + TVP_WADR_PAL] = 0;
    for (i = 0; i < 1024; i++) {
	/* the DAC wants cursor RAM writes during blanking, one per line */
	for (wait = 0; wait < 100000 && (inb(0x3DA) & 1); wait++)
	    ;
	for (wait = 0; wait < 100000 && !(inb(0x3DA) & 1); wait++)
	    ;
	ctl[RAMDAC_OFFSET + TVP_CUR_RAM] = ram[i];
    }
    cursorFrame = frame;
}

- (void)positionCursor:(Point *)loc frame:(int)frame from:(unsigned char *)p
{
    int hot = *(int *)(p + EVP_HOT + 4 * frame);
    int x = loc->x - *(short *)(p + EVP_MINX) - (short)(hot & 0xFFFF) + 64;
    int y = loc->y - *(short *)(p + EVP_MINY) - (short)(hot >> 16) + 64;

    ctl[RAMDAC_OFFSET + TVP_CUR_XLOW] = x & 0xFF;
    ctl[RAMDAC_OFFSET + TVP_CUR_XHI] = (x >> 8) & 0x0F;
    ctl[RAMDAC_OFFSET + TVP_CUR_YLOW] = y & 0xFF;
    ctl[RAMDAC_OFFSET + TVP_CUR_YHI] = (y >> 8) & 0x0F;
}

- (void)cursorEnable:(BOOL)on
{
    unsigned char old;

    DAC_R(ctl, TVP_CURSOR_CTL, old);
    if (on)
	DAC_W(ctl, TVP_CURSOR_CTL, (old & 0x6C) | 0x13);	/* X11 mode */
    else
	DAC_W(ctl, TVP_CURSOR_CTL, old & 0xFC);
}

- showCursor:(Point *)loc frame:(int)frame token:(int)t
{
    unsigned char *p;

    if (!hwCursor || ctl == 0 || (p = evPriv(self)) == 0)
	return [super showCursor:loc frame:frame token:t];
    if (!ev_try_lock((ev_lock_t)(p + EVP_LOCK)))
	return self;
    {
	static int logged;

	if (!logged) {
	    logged = 1;
	    IOLog("%s: hardware cursor: state %08x, frame %d, bounds %d..%d x %d..%d,"
		  " loc %d,%d\n", [self name], (unsigned int)p, frame,
		  *(short *)(p + EVP_MINX), *(short *)(p + EVP_MAXX),
		  *(short *)(p + EVP_MINY), *(short *)(p + EVP_MAXY),
		  loc->x, loc->y);
	}
    }
    [self loadCursorFrame:frame from:p];
    [self positionCursor:loc frame:cursorFrame from:p];
    [self cursorEnable:YES];
    ev_unlock((ev_lock_t)(p + EVP_LOCK));
    return self;
}

- moveCursor:(Point *)loc frame:(int)frame token:(int)t
{
    unsigned char *p;

    if (!hwCursor || ctl == 0 || (p = evPriv(self)) == 0)
	return [super moveCursor:loc frame:frame token:t];
    if (!ev_try_lock((ev_lock_t)(p + EVP_LOCK)))
	return self;
    if (frame != cursorFrame) {
	[self cursorEnable:NO];
	[self loadCursorFrame:frame from:p];
	[self cursorEnable:YES];
    }
    [self positionCursor:loc frame:cursorFrame from:p];
    ev_unlock((ev_lock_t)(p + EVP_LOCK));
    return self;
}

- hideCursor:(int)t
{
    unsigned char *p;

    if (!hwCursor || ctl == 0 || (p = evPriv(self)) == 0)
	return [super hideCursor:t];
    if (!ev_try_lock((ev_lock_t)(p + EVP_LOCK)))
	return self;
    [self cursorEnable:NO];
    ev_unlock((ev_lock_t)(p + EVP_LOCK));
    return self;
}

- (void)loadPalette
{
    IODisplayInfo *di = [self displayInfo];
    int i, level = brightnessLevel;
    unsigned char r, g, b;

    ctl[RAMDAC_OFFSET + TVP_PIX_RD_MSK] = 0xFF;
    ctl[RAMDAC_OFFSET + TVP_WADR_PAL] = 0;
    for (i = 0; i < 256; i++) {
	if (di->bitsPerPixel == IO_8BitsPerPixel && redTransferTable != 0 &&
	    di->colorSpace == IO_RGBColorSpace) {
	    int t = i * transferTableCount / 256;

	    r = redTransferTable[t];
	    g = greenTransferTable[t];
	    b = blueTransferTable[t];
	} else if (di->bitsPerPixel == IO_8BitsPerPixel &&
		   redTransferTable != 0) {
	    int t = i * transferTableCount / 256;

	    r = g = b = redTransferTable[t];
	} else {
	    r = g = b = i;
	}
	if (di->bitsPerPixel == IO_8BitsPerPixel) {
	    r = EV_SCALE_BRIGHTNESS(level, r);
	    g = EV_SCALE_BRIGHTNESS(level, g);
	    b = EV_SCALE_BRIGHTNESS(level, b);
	}
	palShadow[i][0] = r;
	palShadow[i][1] = g;
	palShadow[i][2] = b;
	ctl[RAMDAC_OFFSET + TVP_COL_PAL] = r;
	ctl[RAMDAC_OFFSET + TVP_COL_PAL] = g;
	ctl[RAMDAC_OFFSET + TVP_COL_PAL] = b;
    }
}

- (void)programMode
{
    IODisplayInfo *di = [self displayInfo];
    const MGAMode *md = di->parameters;
    const MGATiming *tm = md->timing;
    unsigned char dac[MGA_DACREGS], ext[6], dclk[6], crtc[MGAVGA_CRTC_COUNT];
    MGAVGAMode vm;
    const unsigned char *init;
    int hd, hs, he, ht, vd, vs, ve, vt, wd, shift, k;
    int m, n, p, lm, ln, lp, lq;
    unsigned int fpll, z100, option;
    int timeout;

    shift = md->bytesPerPixelShift;
    switch (md->depth) {
    case 8: init = DACbpp8; break;
    case 16: init = DACbpp16; break;
    default: init = DACbpp32; break;
    }
    memcpy(dac, init, MGA_DACREGS);
    if (md->depth == 16 && md->rgb555)
	dac[1] &= ~0x01;
    if (interleave)
	dac[2] += 1;
    else
	shift++;

    hd = (tm->hdisp >> 3) - 1;
    hs = (tm->hss >> 3) - 1;
    he = (tm->hse >> 3) - 1;
    ht = (tm->htot >> 3) - 1;
    vd = tm->vdisp - 1;
    vs = tm->vss - 1;
    ve = tm->vse - 1;
    vt = tm->vtot - 2;
    if ((ht & 7) == 6 || (ht & 7) == 4)
	ht++;
    wd = tm->hdisp >> (4 - shift);
    /* wd computed with the (possibly bumped) shift, as the X driver does */

    ext[0] = (wd & 0x300) >> 4;
    ext[1] = (((ht - 4) & 0x100) >> 8) | ((hd & 0x100) >> 7) |
	     ((hs & 0x100) >> 6) | (ht & 0x40);
    ext[2] = ((vt & 0xc00) >> 10) | ((vd & 0x400) >> 8) |
	     ((vd & 0xc00) >> 7) | ((vs & 0xc00) >> 5);
    ext[3] = ((1 << shift) - 1) | 0x80;
    ext[3] |= (vramBytes == (8 << 20)) ? 0x10 : (vramBytes == (2 << 20)) ?
	      0x08 : 0x00;
    ext[4] = 0;
    ext[5] = 0;

    memset(crtc, 0, sizeof(crtc));
    crtc[0] = ht - 4;
    crtc[1] = hd;
    crtc[2] = hd;
    crtc[3] = (ht & 0x1F) | 0x80;
    crtc[4] = hs;
    crtc[5] = ((ht & 0x20) << 2) | (he & 0x1F);
    crtc[6] = vt & 0xFF;
    crtc[7] = ((vt & 0x100) >> 8) | ((vd & 0x100) >> 7) |
	      ((vs & 0x100) >> 6) | ((vd & 0x100) >> 5) | 0x10 |
	      ((vt & 0x200) >> 4) | ((vd & 0x200) >> 3) | ((vs & 0x200) >> 2);
    crtc[9] = ((vd & 0x200) >> 4) | 0x40;
    crtc[16] = vs & 0xFF;
    crtc[17] = (ve & 0x0F) | 0x20;
    crtc[18] = vd & 0xFF;
    crtc[19] = wd & 0xFF;
    crtc[21] = vd & 0xFF;
    crtc[22] = (vt + 1) & 0xFF;
    crtc[23] = 0xC3;
    crtc[24] = 0xFF;

    /* sync polarity lives in TVP3026 reg 0x1D (index 5) */
    if (tm->posHSync)
	dac[5] |= 0x01;
    if (tm->posVSync)
	dac[5] |= 0x02;

    /* Pixel clock PLL and loop clock PLL. */
    fpll = calcClock(tm->clock, TI_MAX_VCO_FREQ, &m, &n, &p);
    dclk[0] = (n & 0x3f) | 0xc0;
    dclk[1] = (m & 0x3f);
    dclk[2] = (p & 0x03) | 0xb0;
    lm = 65 - 4;
    ln = 65 - 4 * (64 / 8) / (1 << shift);
    z100 = (2750000 * (65 - ln)) / fpll;
    lq = 0;
    if (z100 <= 200)
	lp = 0;
    else if (z100 <= 400)
	lp = 1;
    else if (z100 <= 800)
	lp = 2;
    else if (z100 <= 1600)
	lp = 3;
    else {
	lp = 3;
	lq = z100 / 1600;
    }
    dclk[3] = (ln & 0x3f) | 0xc0;
    dclk[4] = (lm & 0x3f);
    dclk[5] = (lp & 0x03) | 0xf0;
    dac[18] = lq | 0x38;

    /* VGA part: 256-colour chain-4 graphics, RAM aperture disabled. */
    memset(&vm, 0, sizeof(vm));
    vm.misc = 0xED;
    vm.seq[0] = 0x03;
    vm.seq[1] = 0x01;
    vm.seq[2] = 0x0F;
    vm.seq[3] = 0x00;
    vm.seq[4] = 0x0E;
    memcpy(vm.crtc, crtc, MGAVGA_CRTC_COUNT);
    for (k = 0; k < 16; k++)
	vm.attr[k] = k;
    vm.attr[0x10] = 0x41;
    vm.attr[0x11] = 0x00;
    vm.attr[0x12] = 0x0F;
    vm.attr[0x13] = 0x00;
    vm.grfx[5] = 0x40;
    vm.grfx[6] = 0x05;
    vm.grfx[7] = 0x0F;
    vm.grfx[8] = 0xFF;

    /* --- hardware, in the order MGA3026Restore uses --- */
    for (k = 0; k < 6; k++) {
	outb(CRTCEXT_INDEX, k);
	outb(CRTCEXT_DATA, ext[k]);
    }
    option = ((savedOption & ~OPTION_MASK) | (0x402C0100 & OPTION_MASK));
    if (interleave)
	option |= 0x1000;
    option &= ~0x20000000;
    [self setPCIConfigData:option atRegister:PCI_OPTION_REG];

    DAC_W(ctl, TVP_CLK_SEL, dac[3]);
    DAC_W(ctl, TVP_PLL_ADDR, 0x2A);
    DAC_W(ctl, TVP_LOAD_CLK_DATA, 0);
    DAC_W(ctl, TVP_PIX_CLK_DATA, 0);

    MGAVGASetModeData(&vm);

    /* pixel clock PLL */
    DAC_W(ctl, TVP_PLL_ADDR, 0x00);
    for (k = 0; k < 3; k++)
	DAC_W(ctl, TVP_PIX_CLK_DATA, dclk[k]);
    DAC_W(ctl, TVP_PLL_ADDR, 0x3F);
    for (timeout = 1000000; timeout > 0; timeout--) {
	unsigned char v;

	DAC_R(ctl, TVP_PIX_CLK_DATA, v);
	if (v & 0x40)
	    break;
    }
    if (timeout == 0)
	IOLog("%s: pixel clock PLL did not lock.\n", [self name]);

    DAC_W(ctl, TVP_MCLK_CTL, dac[18]);

    /* loop clock PLL */
    DAC_W(ctl, TVP_PLL_ADDR, 0x00);
    for (k = 3; k < 6; k++)
	DAC_W(ctl, TVP_LOAD_CLK_DATA, dclk[k]);
    DAC_W(ctl, TVP_PLL_ADDR, 0x3F);
    for (timeout = 1000000; timeout > 0; timeout--) {
	unsigned char v;

	DAC_R(ctl, TVP_LOAD_CLK_DATA, v);
	if (v & 0x40)
	    break;
    }
    if (timeout == 0)
	IOLog("%s: loop clock PLL did not lock.\n", [self name]);

    for (k = 0; k < MGA_DACREGS; k++)
	DAC_W(ctl, MGADACregs[k], dac[k]);
    IOLog("%s: mode set: ext %02x %02x %02x %02x opt %08x pll %02x %02x %02x "
	  "loop %02x %02x %02x q%d\n", [self name], ext[0], ext[1], ext[2],
	  ext[3], option, dclk[0], dclk[1], dclk[2], dclk[3], dclk[4],
	  dclk[5], lq);
}

- (void)enterLinearMode
{
    IODisplayInfo *di = [self displayInfo];

    [self programMode];
    cursorFrame = -1;
    [self loadPalette];
    memset(di->frameBuffer, 0, di->memorySize);
}

- (void)revertToVGAMode
{
    int k;

    if (hwCursor && ctl)
	[self cursorEnable:NO];
    if (saved) {
	for (k = 0; k < 6; k++) {
	    outb(CRTCEXT_INDEX, k);
	    outb(CRTCEXT_DATA, savedExt[k]);
	}
	[self setPCIConfigData:savedOption atRegister:PCI_OPTION_REG];
	DAC_W(ctl, TVP_CLK_SEL, savedDac[3]);
    }
    MGAVGASetText();
    if (saved) {
	for (k = 0; k < MGA_DACREGS; k++)
	    DAC_W(ctl, MGADACregs[k], savedDac[k]);
    }
    [super revertToVGAMode];
}

- setBrightness:(int)level token:(int)t
{
    if (level < EV_SCREEN_MIN_BRIGHTNESS || level > EV_SCREEN_MAX_BRIGHTNESS) {
	IOLog("%s: invalid brightness level `%d'.\n", [self name], level);
	return nil;
    }
    brightnessLevel = level;
    [self loadPalette];
    return self;
}

- setTransferTable:(const unsigned int *)table count:(int)numEntries
{
    int k;
    IODisplayInfo *di = [self displayInfo];

    if (redTransferTable != 0)
	IOFree(redTransferTable, 3 * transferTableCount);
    redTransferTable = 0;
    transferTableCount = numEntries;
    if (di->bitsPerPixel != IO_8BitsPerPixel)
	return self;

    redTransferTable = IOMalloc(3 * numEntries);
    greenTransferTable = redTransferTable + numEntries;
    blueTransferTable = greenTransferTable + numEntries;
    if (di->colorSpace == IO_OneIsWhiteColorSpace) {
	for (k = 0; k < numEntries; k++)
	    redTransferTable[k] = greenTransferTable[k] =
		blueTransferTable[k] = table[k] & 0xFF;
    } else {
	for (k = 0; k < numEntries; k++) {
	    redTransferTable[k] = (table[k] >> 24) & 0xFF;
	    greenTransferTable[k] = (table[k] >> 16) & 0xFF;
	    blueTransferTable[k] = (table[k] >> 8) & 0xFF;
	}
    }
    [self loadPalette];
    return self;
}

@end
