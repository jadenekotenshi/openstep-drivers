#!/bin/sh
# Install the MatroxMGA2164W display driver on OPENSTEP 4.2 / x86.  Run as root
# from the directory that contains prebuilt/ (or a built MatroxMGA2164W.config):
#     sh install.sh [path/to/MatroxMGA2164W.config]
set -e
BUNDLE=${1:-prebuilt/MatroxMGA2164W.config}
DEV=/usr/Devices
TABLE=$DEV/System.config/Instance0.table

if [ ! -f "$BUNDLE/MatroxMGA2164W_reloc" ]; then
    echo "install.sh: $BUNDLE/MatroxMGA2164W_reloc not found" >&2
    exit 1
fi
if [ ! -f "$TABLE" ]; then
    echo "install.sh: $TABLE not found" >&2
    exit 1
fi
if grep MatroxMGA2164W "$TABLE" >/dev/null 2>&1; then
    echo "MatroxMGA2164W is already in Active Drivers; replacing the bundle only."
    rm -rf $DEV/MatroxMGA2164W.config
    cp -r "$BUNDLE" $DEV/MatroxMGA2164W.config
    chown -R root $DEV/MatroxMGA2164W.config
    exit 0
fi

rm -rf $DEV/MatroxMGA2164W.config
cp -r "$BUNDLE" $DEV/MatroxMGA2164W.config
chown -R root $DEV/MatroxMGA2164W.config

cp $TABLE $TABLE.pre-mga2164
# Swap the stock Millennium (I) driver for this one, or append ours.
sed -e 's/MatroxMGA2064WDisplayDriver/MatroxMGA2164W/' $TABLE > /tmp/Instance0.table.$$
if ! grep MatroxMGA2164W /tmp/Instance0.table.$$ >/dev/null 2>&1; then
    sed -e 's/\("Active Drivers" = ".*\)";/\1 MatroxMGA2164W";/' \
	/tmp/Instance0.table.$$ > /tmp/Instance0.table.$$.2
    mv /tmp/Instance0.table.$$.2 /tmp/Instance0.table.$$
fi
cp /tmp/Instance0.table.$$ $TABLE
rm -f /tmp/Instance0.table.$$

echo "Installed. Active Drivers now:"
grep "Active Drivers" $TABLE
echo "Previous table saved as $TABLE.pre-mga2164"
echo "Reboot to load it:  /etc/shutdown -r now"
