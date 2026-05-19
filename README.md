# iso

This repository builds an autoinstall USB and can attach a cloud-init seed.

## Host-agnostic cloud-init workflow

Use a shared base configuration plus one host-specific override file.

### Files

- `etc/user-data.base.yml`: common autoinstall defaults for all hosts
- `etc/meta-data.base.yml`: common cloud-init metadata defaults
- `etc/hosts/<host>.yml`: single host file containing both `user-data` and `meta-data` overrides
- `build-deployment-config.sh`: merges base + host overrides into deployable files

### Build host deployment config

```bash
./build-deployment-config.sh -h kubi03
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