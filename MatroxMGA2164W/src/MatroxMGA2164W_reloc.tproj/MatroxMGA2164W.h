/*
 * MatroxMGA2164W -- DriverKit display driver for the Matrox Millennium II
 * (MGA-2164W with TVP3026 RAMDAC), PCI device 0x051B / 0x051F.
 *
 * TVP3026 / MGA-2164W programming sequences follow the X.Org xf86-video-mga
 * driver (see NOTICE: Robin Cutshaw, Harald Koenig,
 * Xavier Ducoin, Doug Merritt et al.).
 */
#ifndef MATROXMGA2164W_H__
#define MATROXMGA2164W_H__

#import <driverkit/IOFrameBufferDisplay.h>
#import <driverkit/i386/IOPCIDeviceDescription.h>
#import <driverkit/i386/IOPCIDirectDevice.h>

#define MGA_DACREGS	21

/* One entry per (timing, depth) combination; IODisplayInfo.parameters. */
typedef struct MGATiming {
    int clock;			/* pixel clock, kHz */
    int hdisp, hss, hse, htot;
    int vdisp, vss, vse, vtot;
    int posHSync, posVSync;
} MGATiming;

typedef struct MGAMode {
    const MGATiming *timing;
    int bytesPerPixelShift;	/* 0, 1, 2 for 8, 16, 32 bits per pixel */
    int depth;			/* bits per pixel: 8, 16, 32 */
    int rgb555;			/* 16 bpp is 5:5:5 */
} MGAMode;

extern const MGATiming MGATimings[];
extern const int MGATimingCount;
extern const int MGADefaultMode;

/* Fills `table' (room for MGAModeCount entries) and returns the count. */
extern int MGABuildModeTable(IODisplayInfo *table, MGAMode *modes,
			     unsigned int vramBytes);
#define MGAModeMax	64

@interface MatroxMGA2164W:IOFrameBufferDisplay
{
    volatile unsigned char *ctl;	/* mapped control registers (16 KB) */
    unsigned int lfbPhys;		/* physical address of the aperture */
    unsigned int lfbSize;
    unsigned int ctlPhys;
    unsigned int vramBytes;
    int interleave;
    unsigned int savedOption;
    unsigned char savedExt[6];
    unsigned char savedDac[MGA_DACREGS];
    int saved;
    int mtrrSlot;		/* variable MTRR we own, or -1 */

    IODisplayInfo modeTable[MGAModeMax];
    MGAMode modeData[MGAModeMax];
    int modeCount;

    unsigned char *redTransferTable;
    unsigned char *greenTransferTable;
    unsigned char *blueTransferTable;
    int transferTableCount;
    int brightnessLevel;
}
+ (BOOL)probe:deviceDescription;
- initFromDeviceDescription:deviceDescription;
- (void)enterLinearMode;
- (void)revertToVGAMode;
- free;
- setBrightness:(int)level token:(int)t;
- setTransferTable:(const unsigned int *)table count:(int)numEntries;
@end

#endif
