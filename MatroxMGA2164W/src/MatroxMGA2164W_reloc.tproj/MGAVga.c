/*
 * MGAVga.c -- load a complete set of standard VGA registers.
 */
#import <driverkit/i386/ioPorts.h>
#import "MGAVga.h"

#define ATTR		0x3C0
#define MISC_W		0x3C2
#define SEQ_I		0x3C4
#define SEQ_D		0x3C5
#define GRFX_I		0x3CE
#define GRFX_D		0x3CF
#define CRTC_I		0x3D4
#define CRTC_D		0x3D5
#define STATUS1		0x3DA

void
MGAVGASetModeData(const MGAVGAMode *m)
{
    int k;

    /* Give the palette to the CPU (blanks the display), reset the sequencer. */
    inb(STATUS1);
    outb(ATTR, 0x00);
    outb(SEQ_I, 0x00);
    outb(SEQ_D, 0x01);

    outb(MISC_W, m->misc);
    for (k = 1; k < MGAVGA_SEQ_COUNT; k++) {
	outb(SEQ_I, k);
	outb(SEQ_D, m->seq[k]);
    }
    outb(SEQ_I, 0x00);
    outb(SEQ_D, 0x03);

    /* CRTC 0-7 are write protected by bit 7 of register 0x11. */
    outb(CRTC_I, 0x11);
    outb(CRTC_D, 0x00);
    for (k = 0; k < MGAVGA_CRTC_COUNT; k++) {
	outb(CRTC_I, k);
	outb(CRTC_D, m->crtc[k]);
    }

    for (k = 0; k < MGAVGA_GRFX_COUNT; k++) {
	outb(GRFX_I, k);
	outb(GRFX_D, m->grfx[k]);
    }

    inb(STATUS1);			/* attribute flip-flop to "index" */
    for (k = 0; k < MGAVGA_ATTR_COUNT; k++) {
	outb(ATTR, k);
	outb(ATTR, m->attr[k]);
    }

    inb(STATUS1);
    outb(ATTR, 0x20);			/* palette back to the VGA: display on */
}

/* Standard 720x400 colour text mode (BIOS mode 3). */
static const MGAVGAMode textMode = {
    0x67,
    { 0x03, 0x01, 0x03, 0x00, 0x02 },
    { 0x5f, 0x4f, 0x50, 0x82, 0x55, 0x81, 0xbf, 0x1f, 0x00, 0x4f,
      0x0d, 0x0e, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x28,
      0x1f, 0x96, 0xb9, 0xa3, 0xff },
    { 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07, 0x38, 0x39,
      0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x0c, 0x00, 0x0f, 0x08, 0x00 },
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0e, 0x00, 0xff },
};

void
MGAVGASetText(void)
{
    MGAVGASetModeData(&textMode);
}
