# uiDivStats - WebUI for Diversion statistics

## v4.0.0

### Updated on April 14, 2024 by @decoderman

## About

A graphical representation of domain blocking performed by Diversion.

uiDivStats is free to use under the [GNU General Public License version 3](https://opensource.org/licenses/GPL-3.0) (GPL 3.0).


## Supported firmware versions

You must be running firmware Merlin 384.15/384.13_4 or Fork 43E5 (or later) [Asuswrt-Merlin](https://asuswrt.lostrealm.ca/)

## Installation
uiDivStats is available to install with [amtm - the Asuswrt-Merlin Terminal Menu](https://github.com/decoderman/amtm)
Using your preferred SSH client/terminal, open amtm and use the i install option to install uiDivStats:
```sh
amtm
```

Using your preferred SSH client/terminal, copy and paste the following command, then press Enter:

```sh
/usr/sbin/curl --retry 3 "https://raw.githubusercontent.com/decoderman/uiDivStats/master/uiDivStats.sh" -o "/jffs/scripts/uiDivStats" && chmod 0755 /jffs/scripts/uiDivStats && /jffs/scripts/uiDivStats install
```

## Usage

### WebUI

uiDivStats can be configured via the WebUI, in the LAN section.

### CLI

To launch the uiDivStats menu after installation, use:

```sh
uiDivStats
```

If this does not work, you will need to use the full path:

```sh
/jffs/scripts/uiDivStats
```

## Help

Please post about any issues and problems here: [uiDivStats on SNBForums](https://www.snbforums.com/forums/asuswrt-merlin-addons.60/?prefix_id=15)
