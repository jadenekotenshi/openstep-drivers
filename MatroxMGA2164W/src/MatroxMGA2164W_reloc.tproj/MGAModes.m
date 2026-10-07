/*
 * Mode timings (VESA DMT) and the IODisplayInfo table for the Millennium II.
 */
#import <driverkit/displayDefs.h>
#import <string.h>
#import "MatroxMGA2164W.h"

const MGATiming MGATimings[] = {
    /* clk    hd   hss   hse   ht   vd  vss  vse   vt  +h +v */
    {  25175, 640,  656,  752,  800, 480, 490, 492, 525, 0, 0 },	/* 60 */
    {  40000, 800,  840,  968, 1056, 600, 601, 605, 628, 1, 1 },
    {  65000, 1024, 1048, 1184, 1344, 768, 771, 777, 806, 0, 0 },
    { 108000, 1280, 1328, 1440, 1688, 1024, 1025, 1028, 1066, 1, 1 },
    {  31500, 640,  656,  720,  840, 480, 481, 484, 500, 0, 0 },	/* 75 */
    {  49500, 800,  816,  896, 1056, 600, 601, 604, 625, 1, 1 },
    {  78750, 1024, 1040, 1136, 1312, 768, 769, 772, 800, 1, 1 },
    { 135000, 1280, 1296, 1440, 1688, 1024, 1025, 1028, 1066, 1, 1 },
};
const int MGATimingCount = sizeof(MGATimings) / sizeof(MGATimings[0]);
const int MGADefaultMode = 0;

static const int refresh[] = { 60, 60, 60, 60, 75, 75, 75, 75 };

static const struct {
    int depth;
    int shift;
    IOBitsPerPixel bpp;
    IOColorSpace cs;
    const char *enc;
    int rgb555;
} depths[] = {
    { 8,  0, IO_8BitsPerPixel, IO_RGBColorSpace, "PPPPPPPP", 0 },
    { 8,  0, IO_8BitsPerPixel, IO_OneIsWhiteColorSpace, "WWWWWWWW", 0 },
    { 16, 1, IO_15BitsPerPixel, IO_RGBColorSpace, "-RRRRRGGGGGBBBBB", 1 },
    { 32, 2, IO_24BitsPerPixel, IO_RGBColorSpace,
      "--------RRRRRRRRGGGGGGGGBBBBBBBB", 0 },
};

int
MGABuildModeTable(IODisplayInfo *table, MGAMode *modes, unsigned int vram)
{
    int t, d, n = 0;

    for (t = 0; t < MGATimingCount && n < MGAModeMax; t++) {
	for (d = 0; d < 4 && n < MGAModeMax; d++) {
	    const MGATiming *tm = &MGATimings[t];
	    IODisplayInfo *di = &table[n];
	    unsigned int rowBytes = tm->hdisp << depths[d].shift;

	    memset(di, 0, sizeof(*di));
	    di->width = di->totalWidth = di->screenWidth = tm->hdisp;
	    di->height = di->screenHeight = tm->vdisp;
	    di->rowBytes = rowBytes;
	    di->refreshRate = refresh[t];
	    di->bitsPerPixel = depths[d].bpp;
	    di->colorSpace = depths[d].cs;
	    strcpy(di->pixelEncoding, depths[d].enc);
	    di->memorySize = rowBytes * tm->vdisp;
	    di->dotClockRate = tm->clock * 1000;
	    di->scanRate = (tm->clock * 1000) / tm->htot;
	    modes[n].timing = tm;
	    modes[n].bytesPerPixelShift = depths[d].shift;
	    modes[n].depth = depths[d].depth;
	    modes[n].rgb555 = depths[d].rgb555;
	    di->parameters = &modes[n];
	    if ((unsigned int)di->memorySize > vram)
		di->modeUnavailableFlag = IO_DISPLAY_MODE_NEEDS_MORE_MEMORY;
	    n++;
	}
    }
    return n;
}
