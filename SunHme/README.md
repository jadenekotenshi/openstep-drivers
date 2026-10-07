# SunHme: OPENSTEP 4.2 (SPARC) driver for the SunSwift SBus HME

Network driver for the `SUNW,hme` SBus card that the `sun-hme-sbus` QEMU device
(`-device sun-hme-sbus,...` or `-nic user,model=hme`) presents on SS-5/10/20/600MP.

* `prebuilt/SunHme.config/`  built bundle (SPARC), ready to copy to `/usr/Devices`
* `src/`            DriverKit project (copy to the guest and run `make`; `make install`
                    puts the bundle in `/usr/Devices`)

## Install in the guest (as root)

    cp -R prebuilt/SunHme.config /usr/Devices/
    chown -R root.wheel /usr/Devices/SunHme.config
    # load it at boot: append SunHme to "Active Drivers" in /usr/Devices/System.config/Instance0.table
    #   "Active Drivers" = "SUNMouse SunAudio SunHme";
    # give the new interface an address, or the boot stalls for minutes in
    # "Configuring Network" (the catch-all `*` rule in /etc/iftab asks for a BOOTP
    # address). Add before the `*` line:
    #   en1   inet   <address> netmask <mask> -trailers up
    shutdown -r now

The interface appears as `en1` (`en0` stays the Lance) and the log shows
`hme0: SunSwift SBus HME, ethernet address ...`.

## Notes

* PROM node `SUNW,hme`, 5 register sets, SBus level 4 (`"IRQ Levels" = 0x37`, i.e. 0x30 | PIL 7).
  If you attach the card at another `irq-level`, change the tables: 0x30 | {0,2,3,5,7,9,11,13}[level].
* MAC address comes from the card's `local-mac-address` property (QEMU `mac=`), falling back to the IDPROM.
* DMA: one 128 KB block mapped with `mb_nbmapalloc`; 32 RX and 16 TX descriptors, frames are copied.
* Verified only against the QEMU HME model (ping and bulk TCP through `en1`), not real hardware.
