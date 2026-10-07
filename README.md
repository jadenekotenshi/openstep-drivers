# openstep-drivers

DriverKit drivers for OPENSTEP 4.2, written against emulators (86Box, QEMU).

| Directory | Platform | What |
|---|---|---|
| [`MatroxMGA2164W`](MatroxMGA2164W/) | x86 | Matrox Millennium II display driver with MTRR write combining |
| [`SunHme`](SunHme/) | SPARC | SunSwift SBus HME (`SUNW,hme`) network driver |

Each directory has `src/` (the DriverKit project), `prebuilt/` (a built bundle) and a README with install steps.
