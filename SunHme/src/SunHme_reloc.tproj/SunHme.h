/*
 * Driver class for the SunSwift SBus HME FastEthernet card (SUNW,hme).
 */

#import <driverkit/IOEthernet.h>
#import <driverkit/sparc/directDevice.h>
#import <driverkit/IONetbufQueue.h>
#import "SunHmeHdw.h"

@interface SunHme:IOEthernet
{
    IONetwork		*network;	/* handle to kernel network object   */
    enet_addr_t		myAddress;
    unsigned int	hmeUnit;	/* index into the interrupt tables   */

    BOOL		promiscEnabled;
    BOOL		multicastEnabled;

    vm_offset_t		dmaVA;		/* rings and buffers, kernel address */
    unsigned long	dmaDVMA;	/* the same, as the chip sees it     */
    unsigned int	rxCons;		/* next receive descriptor to check  */
    unsigned int	txProd;		/* next transmit descriptor to fill  */
    unsigned int	txCons;		/* oldest unreclaimed transmit desc  */
}

+ (BOOL)probe:(IODeviceDescription *)devDesc;

- initFromDeviceDescription:(IODeviceDescription *)devDesc;
- free;

- (BOOL)getHandler:(IOInterruptHandler *)handler
	     level:(unsigned int *)ipl
	  argument:(unsigned int *)arg
      forInterrupt:(unsigned int)localInterrupt;

- (IOReturn)enableAllInterrupts;
- (void)disableAllInterrupts;
- (BOOL)resetAndEnable:(BOOL)enable;
- (void)timeoutOccurred;
- (void)interruptOccurred;

- (BOOL)enablePromiscuousMode;
- (void)disablePromiscuousMode;
- (BOOL)enableMulticastMode;
- (void)disableMulticastMode;
- (void)addMulticastAddress:(enet_addr_t *)addr;
- (void)removeMulticastAddress:(enet_addr_t *)addr;

- (void)transmit:(netbuf_t)pkt;

@end
