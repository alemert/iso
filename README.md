# iso

This repository builds an autoinstall USB and can attach a cloud-init seed.

## Host-agnostic cloud-init workflow

Use a layered configuration model:

1. Base user-data for shared settings
2. Optional boot-mode override (`bios` or `efi`)
3. Host-specific override

### Files

- `etc/user-data.base.yml`: common autoinstall defaults for all hosts
- `etc/user-data.bios.yml` / `etc/user-data.efi.yml`: optional boot-mode overrides
- `etc/meta-data.base.yml`: common cloud-init metadata defaults
- Preferred host files:
	- `etc/hosts/<host>/user-data.yml`
	- `etc/hosts/<host>/meta-data.yml`
- Backward compatible legacy host file:
	- `etc/hosts/<host>.yml` with top-level `user-data` and `meta-data`
- `build-deployment-config.sh`: merges base + host overrides into deployable files

### Build host deployment config

```bash
./build-deployment-config.sh -h kubi03
```

With explicit boot mode:

```bash
./build-deployment-config.sh -h kubi03 -b bios
```

This generates:

- `etc/deploy/kubi03/user-data`
- `etc/deploy/kubi03/meta-data`

### Create USB using generated deployment config

```bash
sudo ./usb4iso.sh -i ~/Downloads/linux.iso -d /dev/sdb \
	-u ./etc/deploy/kubi03/user-data \
	-m ./etc/deploy/kubi03/meta-data
```

### Dependency

`build-deployment-config.sh` uses `yq` (mikefarah/yq) for YAML merge.

### Merge order

`user-data` merge is left-to-right, where later files override earlier files:

1. `user-data.base.yml`
2. `user-data.<boot-mode>.yml` (when `-b` is provided)
3. host `user-data` override

`meta-data` merge order:

1. `meta-data.base.yml`
2. host `meta-data` override