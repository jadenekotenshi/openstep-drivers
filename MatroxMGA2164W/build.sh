#!/bin/sh
# Build the bundle on an OPENSTEP 4.2 / x86 box with the Developer tools.
# Copy src/ over (COPYFILE_DISABLE=1 tar --format ustar if tarring on a Mac),
# then:  cd src && sh ../build.sh   ->  src/MatroxMGA2164W.config
#
# The stock bundle.make step that links the (empty) bundle stub fails on i386
# ("cc: No input files"), so the stub is built by hand.
make
echo "static int unused;" > Stub.c
cc -static -O -arch i386 -nostdlib -r -o MatroxMGA2164W.config/MatroxMGA2164W Stub.c
rm -f Stub.c
ls -l MatroxMGA2164W.config
