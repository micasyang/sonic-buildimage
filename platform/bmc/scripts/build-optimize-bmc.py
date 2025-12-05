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

class File:
    def __init__(self, path):
        self.path = path

    def __str__(self):
        return self.path

    def rmtree(self):
        if DRY_RUN:
           print(f'rmtree {self.path}')
           return
        shutil.rmtree(self.path)

    def hardlink(self, src):
        if DRY_RUN:
           print(f'hardlink {self.path} {src}')
           return
        st = self.stats
        os.remove(self.path)
        os.link(src.path, self.path)
        os.chmod(self.path, st.st_mode)
        os.chown(self.path, st.st_uid, st.st_gid)
        os.utime(self.path, times=(st.st_atime, st.st_mtime))

    @property
    def name(self):
        return os.path.basename(self.path)

    @cached_property
    def stats(self):
        return os.stat(self.path)

    @cached_property
    def size(self):
        return self.stats.st_size

    @cached_property
    def checksum(self):
        with open(self.path, 'rb') as f:
            return hashlib.md5(f.read()).hexdigest()

class FileManager:
    def __init__(self, path):
        self.path = path
        self.files = []
        self.folders = []
        self.nindex = defaultdict(list)
        self.cindex = defaultdict(list)

    def add_file(self, path):
        if not os.path.isfile(path) or os.path.islink(path):
            return
        f = File(path)
        self.files.append(f)

    def load_tree(self):
        self.files = []
        self.folders = []
        for root, _, files in os.walk(self.path):
            self.folders.append(File(root))
            for f in files:
                self.add_file(os.path.join(root, f))
        print(f'loaded {len(self.files)} files and {len(self.folders)} folders')

    def generate_index(self):
        print('Computing file hashes')
        for f in self.files:
            self.nindex[f.name].append(f)
            self.cindex[(f.name, f.checksum)].append(f)

    def create_hardlinks(self):
        print('Creating hard links')
        for files in self.cindex.values():
            if len(files) <= 1:
                continue
            orig = files[0]
            for f in files[1:]:
                f.hardlink(orig)

class FsRoot:
    def __init__(self, path):
        self.path = path

    def iter_fsroots(self):
        yield self.path
        dimgpath = os.path.join(self.path, 'var/lib/docker/overlay2')
        if os.path.isdir(dimgpath):
            for layer in os.listdir(dimgpath):
                yield os.path.join(dimgpath, layer, 'diff')

    def collect_fsroot_size(self):
        cmd = ['du', '-sb', self.path]
        p = subprocess.run(cmd, text=True, check=False,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return int(p.stdout.split()[0])

    def _remove_root_paths(self, relpaths):
        for root in self.iter_fsroots():
            for relpath in relpaths:
                path = os.path.join(root, relpath)
                if os.path.isdir(path):
                    if DRY_RUN:
                        print(f'rmtree {path}')
                    else:
                        shutil.rmtree(path)

    def remove_docs(self):
        self._remove_root_paths([
            'usr/share/doc',
            'usr/share/doc-base',
            'usr/local/share/doc',
            'usr/local/share/doc-base',
        ])

    def remove_mans(self):
        self._remove_root_paths([
            'usr/share/man',
            'usr/local/share/man',
        ])

    def remove_licenses(self):
        self._remove_root_paths([
            'usr/share/common-licenses',
        ])

    def hardlink_under(self, path):
        fm = FileManager(os.path.join(self.path, path))
        fm.load_tree()
        fm.generate_index()
        fm.create_hardlinks()

    def remove_platforms(self, filter_func):
        devpath = os.path.join(self.path, 'usr/share/sonic/device')
        for platform in os.listdir(devpath):
            if not filter_func(platform):
                path = os.path.join(devpath, platform)
                if DRY_RUN:
                    print(f'rmtree platform {path}')
                else:
                    shutil.rmtree(path)

    def remove_platforms2(self, filter_func):
        devpath = os.path.join(self.path, 'usr/share/sonic/device/x86_64-kvm_x86_64-r0')
        for platform in os.listdir(devpath):
            if not filter_func(platform):
                path = os.path.join(devpath, platform)
                if DRY_RUN:
                    print(f'rmtree platform {path}')
                else:
                    if os.path.islink(path):
                        os.unlink(path)  # 删除软链接
                    elif os.path.isfile(path) or os.path.islink(path):
                        os.remove(path)  # 删除文件
                    elif os.path.isdir(path):
                        shutil.rmtree(path)

    def remove_platforms3(self):
        devpath = os.path.join(self.path, 'usr/share/sonic/device/x86_64-kvm_x86_64-r0/Force10-S6000')
        for platform in os.listdir(devpath):
            path = os.path.join(devpath, platform)
            if os.path.islink(path):
                os.unlink(path)  # 删除软链接
            elif os.path.isfile(path) or os.path.islink(path):
                os.remove(path)  # 删除文件
            elif os.path.isdir(path):
                shutil.rmtree(path)

    def remove_modules(self, modules):
        modpath = os.path.join(self.path, 'lib/modules')
        kversion = os.listdir(modpath)[0]
        kmodpath = os.path.join(modpath, kversion)
        for module in modules:
            path = os.path.join(kmodpath, module)
            if os.path.isdir(path):
                if DRY_RUN:
                    print(f'rmtree module {path}')
                else:
                    shutil.rmtree(path)

    def remove_firmwares(self, firmwares):
        fwpath = os.path.join(self.path, 'lib/firmware')
        for fw in firmwares:
            path = os.path.join(fwpath, fw)
            if os.path.isdir(path):
                if DRY_RUN:
                    print(f'rmtree firmware {path}')
                else:
                    shutil.rmtree(path)


    def specialize_aboot_image(self):
        # fp = lambda p: 'x86_64-kvm_x86_64-r0' in p
        fp = lambda p: 'kvm' in p
        # fp = lambda p:  'kvm' in p
        self.remove_platforms(fp)
        fp = lambda p:  'ast2720' == p or 'default_sku' == p or 'platform_asic' == p
        self.remove_platforms2(fp)
        # self.remove_platforms3()
        self.remove_modules([
           'kernel/drivers/gpu',
           'kernel/drivers/infiniband',
        ])
        self.remove_firmwares([
           'amdgpu',
           'i915',
           'mediatek',
           'nvidia',
           'radeon',
        ])

    def specialize_image(self, image_type):
        self.specialize_aboot_image()

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
        keep_dirs = ["squashfs","configfs","ext4","debugfs","securityfs","overlayfs","jbd2","mbcache.ko","autofs","fuse","binfmt_misc.ko"]
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
        # keep_dirs = ["platform","block","bus","gpio","pci","net","i2c","tty","char","serial","hwmon","pwm","power"]
        keep_dirs = ["net"]
        for path in os.listdir(fs_path):
            if any(d in path for d in keep_dirs):
                continue
            else:
                path = os.path.join(fs_path, path)
                remove_path(path)

    def cleanup_specific_files(self):
        paths = [
            '/etc/sonic/asic_config_checksum',
            '/etc/default/kexec'
        ]
        for relpath in paths:
            abspath = os.path.join(self.path, relpath.lstrip('/'))
            if os.path.exists(abspath):
                if DRY_RUN:
                    print(f'[DRY RUN] Would remove: {abspath}')
                else:
                    if os.path.isdir(abspath):
                        shutil.rmtree(abspath)
                    elif os.path.isfile(abspath) or os.path.islink(abspath):
                        os.remove(abspath)

    def cleanup_unnecessary_packages(self):
        apt_get_path = os.path.join(self.path, 'usr', 'bin', 'apt-get')
        if not os.path.isfile(apt_get_path):
            if not DRY_RUN:
                print("[INFO] apt-get not found in rootfs. Skipping package cleanup.")
            return

        cmd_prefix = ['chroot', self.path]

        packages_to_remove = [
            'firmware-linux-nonfree',
            'kexec-tools',
            'ifmetric',
            'iproute2',
            'bridge-utils',
            'vim',
            'tcpdump',
            'traceroute',
            'iputils-ping',
            'arping',
            'net-tools',
            'bsdmainutils',
            'efibootmgr',
            'iptables-persistent',
            'ebtables',
            'curl',
            'less',
            'unzip',
            'gdisk',
            'sysfsutils',
            'screen',
            'hping3',
            'tcptraceroute',
            'mtr-tiny',
            'ipmitool',
            'ndisc6',
            'makedumpfile',
            'conntrack',
            'cron',
            'libprotobuf32',
            'libgrpc29',
            'libgrpc++1.51',
            'haveged',
            'fdisk',
            'gpg',
            'linux-perf',
            'sysstat',
            'xxd',
            'wireless-regdb',
            'nvme-cli'
        ]

        cmd = cmd_prefix + ['apt-get', '-y', 'remove', '--purge'] + packages_to_remove
        if DRY_RUN:
            print(f'[DRY RUN] Would run: {" ".join(cmd)}')
        else:
            print(f"[INFO] Running: {' '.join(cmd)}")
            try:
                subprocess.run(cmd, check=True)
            except subprocess.CalledProcessError as e:
                print(f"[ERROR] Failed to remove packages: {e}")

        cmd = cmd_prefix + ['apt-get', 'autoremove', '--purge', '-y']
        if DRY_RUN:
            print(f'[DRY RUN] Would run: {" ".join(cmd)}')
        else:
            try:
                subprocess.run(cmd, check=True)
            except subprocess.CalledProcessError as e:
                print(f"[ERROR] Failed to autoremove: {e}")

        cmd = cmd_prefix + ['apt-get', 'clean', '-y']
        if DRY_RUN:
            print(f'[DRY RUN] Would run: {" ".join(cmd)}')
        else:
            try:
                subprocess.run(cmd, check=True)
            except subprocess.CalledProcessError as e:
                print(f"[ERROR] Failed to clean apt cache: {e}")

    def create_busy_box(self):
        busy_box_path = os.path.join(self.path, 'opt', 'busybox-bin')
        if not os.path.exists(busy_box_path):
            if DRY_RUN:
                print(f'[DRY RUN] Would create busybox at: {busy_box_path}')
            else:
                os.makedirs(busy_box_path, exist_ok=True)
                cmd = ['chroot', self.path, 'busybox', '--install', '-s', '/opt/busybox-bin']
                subprocess.run(cmd, check=True)
                profile_path = os.path.join(self.path, 'etc', 'profile.d', 'busybox.sh')
                with open(profile_path, 'a') as f:
                    f.write('export PATH="$PATH:/opt/busybox-bin"\n')

    def clear_python(self):
        cmd_prefix = ['chroot', self.path]
        cmd = cmd_prefix + ['pip3', 'uninstall', '-y', 'scapy==2.4.4']
        if DRY_RUN:
            print(f'[DRY RUN] Would run: {" ".join(cmd)}')
        else:
            try:
                subprocess.run(cmd, check=True)
            except subprocess.CalledProcessError as e:
                print(f"[ERROR] Failed to clean apt cache: {e}")

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
    if args.stats:
        begin = fs.collect_fsroot_size()
        print(f'fsroot size is {begin} bytes')

    fs.cleanup_specific_files()
    # fs.cleanup_unnecessary_packages()
    # fs.clear_python()

    fs.clear_kernel_fs()
    fs.clear_kernel_lib()
    fs.clear_kernel_net()
    fs.clear_kernel_drivers()
    fs.clear_kernel_drivers_net()

    fs.remove_docs()
    fs.remove_mans()
    fs.remove_licenses()

    if args.image_type:
        fs.specialize_image(args.image_type)

    for path in args.hardlinks:
        fs.hardlink_under(path)


    # fs.create_busy_box()

    if args.stats:
        end = fs.collect_fsroot_size()
        pct = 100 - end / begin * 100
        print(f'fsroot reduced to {end} from {begin} {pct:.2f}')

    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
