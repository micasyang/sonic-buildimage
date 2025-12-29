# AST2700 U-Boot artifacts

Place OpenBMC-produced boot files here before running `make ast2700-flash`:

- `u-boot-spl.bin` (SPL, prefer the ~80KB variant to avoid overlapping the U-Boot region)
- `u-boot.bin` (main U-Boot)
- `platform.dtb` (AST2700 device tree; e.g. `ast2700-evb.dtb`)

You can extract a DTB from an OpenBMC FIT (e.g. `fitImage-obmc-wb`) with:

```bash
dumpimage -T flat_dt -p 0 fitImage-obmc-wb platform.dtb
```
