#!/usr/bin/env python3

import argparse
import hashlib
import os
import shutil
import subprocess
import sys

from collections import defaultdict
from functools import cached_property

DRY_RUN = False
def enable_dry_run(enabled):
    global DRY_RUN # pylint: disable=global-statement
    DRY_RUN = enabled

class FsRoot:
    def __init__(self, path):
        self.path = path

    def clear_kernel_drivers_net(self):
        modpath = os.path.join(self.path, 'lib/modules')
        kversion = os.listdir(modpath)[0]
        kmodpath = os.path.join(modpath, kversion)
        netpath = os.path.join(kmodpath, 'kernel/drivers/net')
        keep_dirs = ["veth", "ethernet","bonding"]
        for driver in os.listdir(netpath):
            if any(d in driver for d in keep_dirs):
                continue
            else:
                path = os.path.join(netpath, driver)
                remove_path(path)

        eth_path = os.path.join(netpath, 'ethernet')
        for driver in os.listdir(eth_path):
            if 'intel' in driver or 'broadcom' in driver:
                continue
            else:
                path = os.path.join(eth_path, driver)
                remove_path(path)

        eth_path = os.path.join(eth_path, 'intel')
        for driver in os.listdir(eth_path):
            if 'e1000' == driver:
                continue
            else:
                path = os.path.join(eth_path, driver)
                remove_path(path)

    def clear_kernel_fs(self):
        modpath = os.path.join(self.path, 'lib/modules')
        kversion = os.listdir(modpath)[0]
        kmodpath = os.path.join(modpath, kversion)
        fs_path = os.path.join(kmodpath, 'kernel/fs')
        keep_dirs = ["squashfs","configfs","ext4","debugfs","securityfs","overlayfs","jbd2","mbcache.ko","autofs","fuse","binfmt_misc.ko","fat"]
        for path in os.listdir(fs_path):
            if any(d in path for d in keep_dirs):
                continue
            else:
                path = os.path.join(fs_path, path)
                remove_path(path)

    def clear_kernel_lib(self):
        modpath = os.path.join(self.path, 'lib/modules')
        kversion = os.listdir(modpath)[0]
        kmodpath = os.path.join(modpath, kversion)
        fs_path = os.path.join(kmodpath, 'kernel/lib')
        for path in os.listdir(fs_path):
            if "test_" in path:
                path = os.path.join(fs_path, path)
                remove_path(path)

    def clear_kernel_net(self):
        modpath = os.path.join(self.path, 'lib/modules')
        kversion = os.listdir(modpath)[0]
        kmodpath = os.path.join(modpath, kversion)
        fs_path = os.path.join(kmodpath, 'kernel/net')
        keep_dirs = ["bridge","802","llc","tls","bonding"]
        for path in os.listdir(fs_path):
            if path in keep_dirs:
                continue
            else:
                path = os.path.join(fs_path, path)
                remove_path(path)
        patn_802 = os.path.join(fs_path, '802')
        for path in os.listdir(patn_802):
            if path == 'stp.ko':
                continue
            else:
                path = os.path.join(patn_802, path)
                remove_path(path)

    def clear_kernel_drivers(self):
        modpath = os.path.join(self.path, 'lib/modules')
        kversion = os.listdir(modpath)[0]
        kmodpath = os.path.join(modpath, kversion)
        fs_path = os.path.join(kmodpath, 'kernel/drivers')
        keep_dirs = ["platform","block","bus","gpio","pci","net","i2c","tty","char","serial","hwmon","pwm","power","virt","virtio","scsi"]
        # keep_dirs = ["net"]
        for path in os.listdir(fs_path):
            if any(d in path for d in keep_dirs):
                continue
            else:
                path = os.path.join(fs_path, path)
                remove_path(path)

def remove_path(path):
    if DRY_RUN:
        print(f'remove {path}')
        return
    if os.path.isdir(path):
        shutil.rmtree(path)
    else:
        os.remove(path)

def parse_args(args):
    parser = argparse.ArgumentParser()
    parser.add_argument('fsroot',
        help="path to the fsroot build folder")
    parser.add_argument('-s', '--stats', action='store_true',
        help="show space statistics")
    parser.add_argument('--hardlinks', action='append',
        help="path where similar files need to be hardlinked")
    parser.add_argument('--image-type', default=None,
        help="type of image being built")
    parser.add_argument('--dry-run', action='store_true',
        help="only display what would happen")
    return parser.parse_args(args)

def main(args):
    args = parse_args(args)

    enable_dry_run(args.dry_run)

    fs = FsRoot(args.fsroot)

    fs.clear_kernel_fs()
    fs.clear_kernel_lib()
    fs.clear_kernel_net()
    fs.clear_kernel_drivers()
    fs.clear_kernel_drivers_net()

    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))