#!/usr/bin/env python3
"""Check every kernel boot entry, never the build VM's old /proc/cmdline."""
import re
import sys


def verify(lines, grubby=False):
    entries = []
    for line in lines:
        if grubby and line.startswith('args='):
            entries.append(line[5:].strip().strip('"'))
        elif not grubby and re.match(r'^\s*linux(?:efi|16)?\s', line):
            entries.append(line.strip())
    if not entries:
        raise ValueError('No kernel boot entries found')
    for entry in entries:
        tokens = entry.split()
        blacklist = [t.split('=', 1)[1] for t in tokens if t.startswith('modprobe.blacklist=')]
        modeset = [t for t in tokens if t.startswith('nouveau.modeset=')]
        if len(blacklist) != 1 or not {'nouveau', 'amdgpu'} <= set(blacklist[0].split(',')):
            raise ValueError('Missing or duplicate GPU blacklist: ' + entry)
        if modeset != ['nouveau.modeset=0']:
            raise ValueError('Missing or conflicting nouveau modeset: ' + entry)
    return len(entries)


if __name__ == '__main__':
    print('Verified GPU blacklist in %d kernel entries' % verify(sys.stdin, '--grubby' in sys.argv))
