/*
 * MGAVga.h -- programming the standard VGA register file.
 */
#ifndef MGAVGA_H__
#define MGAVGA_H__

#define MGAVGA_SEQ_COUNT	5
#define MGAVGA_CRTC_COUNT	25
#define MGAVGA_ATTR_COUNT	21
#define MGAVGA_GRFX_COUNT	9

typedef struct MGAVGAMode {
    unsigned char misc;				/* 0x3C2 */
    unsigned char seq[MGAVGA_SEQ_COUNT];	/* 0x3C4/5 */
    unsigned char crtc[MGAVGA_CRTC_COUNT];	/* 0x3D4/5 */
    unsigned char attr[MGAVGA_ATTR_COUNT];	/* 0x3C0 */
    unsigned char grfx[MGAVGA_GRFX_COUNT];	/* 0x3CE/F */
} MGAVGAMode;

extern void MGAVGASetModeData(const MGAVGAMode *m);
extern void MGAVGASetText(void);	/* 80x25 colour text, mode 3 */

#endif
