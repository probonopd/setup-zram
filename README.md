# zram Setup Script

A portable, POSIX-compliant shell script to install and configure zram compressed swap across multiple Linux distributions and init systems.

## Motivation

As of early 2026, the current global RAM market is experiencing a severe shortage, driving an __explosion in prices__ for both DDR4 and DDR5 modules as well as server‑grade memory. 

<details>
  A key driver is the rapid shift of chipmakers toward memory for AI data centers, which consumes far more wafer capacity per bit and leaves significantly less production available for conventional PC and mobile DRAM. At the same time, manufacturers had previously cut output after an oversupply period, so inventories entering late 2025 were thin, meaning surging AI and cloud demand quickly translated into spot and contract price spikes of __several hundred percent__ for common DRAM parts. Analysts now expect elevated memory prices and tight supply to persist __at least through 2027__ as new fabrication capacity for both DRAM and NAND comes online slowly, pushing PC, laptop, smartphone, and even automotive makers to raise device prices, reduce default RAM configurations, or accept lower margins in the near term.
</details>

So let's get some "free RAM" by compressing it, trading some CPU usage for more available RAM.

## Features

- **Auto-detection**: Automatically detects distribution, init system, and available RAM
- **Portable**: Works with systemd, OpenRC, and SysVinit init systems
- **Distribution-agnostic**: Runs on Debian, Ubuntu, Alpine, Devuan, Fedora, etc.
- **Smart sizing**: Intelligently calculates zram size based on system RAM
- **Persistent**: Automatically configures swap to persist across reboots
- **Easy management**: Simple install/remove/status commands
- **POSIX-compliant**: Pure shell script, no external dependencies

## Requirements

- Root access
- Linux kernel with zram module support (5.0+)
- Standard Unix utilities: `modprobe`, `mkswap`, `swapon`, `free`
- One of: systemd, OpenRC, or SysVinit

## Installation

```bash
sudo ./setup-zram.sh install
```

Or with a custom zram size (in MB):

```bash
ZRAM_SIZE_MB=2048 sudo ./setup-zram.sh install
```

## Usage

### Install zram (default)
```bash
sudo ./setup-zram.sh install
```

### Check current status
```bash
sudo ./setup-zram.sh status
```

Output example:
```
Init System         : sysvinit
Distribution        : devuan
Total RAM           : 4039 MB

Memory Info:
               total        used        free      shared  buff/cache   available
Mem:           3.9Gi       2.5Gi       500Mi       200Mi       1.0Gi       1.4Gi
Swap:          2.0Gi         10Mi       1.9Gi

ZRAM Swap Info:
/dev/zram0                              partition       2097136         10240           -2

Compression Statistics:
  Original Size: 10 MB
  Compressed Size: 2 MB
  Compression Ratio: 5.00:1
```

### Remove zram
```bash
sudo ./setup-zram.sh remove
```

### Display help
```bash
./setup-zram.sh help
```

## How It Works

### zram Overview

zram creates a compressed RAM-based block device that can be used as swap. Unlike disk-based swap which is slow, zram compression happens in memory with typical compression ratios of 2:1 to 4:1, providing:

- **Fast swap**: Memory-speed I/O instead of disk I/O
- **Memory efficiency**: Compressed data uses 25-50% of original size
- **Automatic**: Transparent to applications

### Sizing Strategy

The script uses a smart heuristic for zram size:

| System RAM | zram Size | Rationale |
|-----------|-----------|-----------|
| < 512 MB  | Not supported | Too little RAM for meaningful swap |
| 512 MB - 2 GB | 25% of RAM | Preserves responsiveness on small systems |
| 2 GB - 8 GB | 50% of RAM | Good swap coverage for medium systems |
| > 8 GB | min(50%, 6 GB) | Caps at 6GB for large systems (= 12-18GB virtual with 2-3:1 compression) |

Override with `ZRAM_SIZE_MB` environment variable:

```bash
ZRAM_SIZE_MB=4096 sudo ./setup-zram.sh install  # Force 4GB zram
```

### Init System Setup

#### systemd
- Service: `/etc/systemd/system/zram.service`
- Init script: `/usr/local/bin/zram-init.sh`
- Auto-start: Yes (enabled via `systemctl enable`)

#### OpenRC
- Init script: `/etc/init.d/zram`
- Auto-start: Yes (registered via `rc-update`)
- Integrates with OpenRC dependency system

#### SysVinit
- Init script: `/etc/init.d/zram`
- Auto-start: Yes (registered via `update-rc.d` or `chkconfig`)

## Performance Characteristics

### Compression Ratios
Typical compression with zstd (default):

| Data Type | Ratio |
|-----------|-------|
| Text | 4:1 - 6:1 |
| Code | 3:1 - 5:1 |
| Binary | 1.5:1 - 3:1 |
| Random | ~1:1 (incompressible) |

### Latency
- zram I/O: ~1-5 microseconds
- SSD swap I/O: ~100-1000 microseconds
- HDD swap I/O: ~5000-50000 microseconds

### When to Use zram

✅ **Good for:**
- Systems with no persistent swap (containers, live systems)
- Increasing available memory without adding RAM
- Reducing memory pressure without disk bottleneck
- Mobile/embedded devices
- Systems with SSD to extend its lifespan

❌ **Not ideal for:**
- Very memory-constrained systems (< 512 MB)
- Systems with insufficient RAM for workload
- As a replacement for proper RAM upgrades

## Verification

After installation, verify zram is working:

```bash
# Check swap is active
free -h
swapon -s | grep zram

# Monitor compression (real-time)
watch -n 1 'cat /sys/block/zram0/mm_stat'

# Test memory pressure
stress --vm 1 --vm-bytes 100M --timeout 60s
```

## Troubleshooting

### zram module not available
```
[ERROR] zram module not available on this system
```

**Solution**: Kernel may not have zram compiled. Check:
```bash
ls -la /lib/modules/$(uname -r)/kernel/drivers/block/zram/
```

If missing, you may need to recompile kernel with `CONFIG_ZRAM=m`.

### Service not auto-starting
Verify the service is enabled:

```bash
# For systemd
sudo systemctl status zram

# For OpenRC
sudo rc-service zram status

# For SysVinit
sudo /etc/init.d/zram status
```

### Permission errors
Ensure you're running with `sudo`:
```bash
sudo ./setup-zram.sh install
```

### Swap not activating
Check kernel logs:
```bash
dmesg | tail -20
sudo modprobe zram num_devices=1
```

## Files Created

```
/etc/systemd/system/zram.service      (systemd only)
/usr/local/bin/zram-init.sh           (systemd only)
/etc/init.d/zram                       (OpenRC/SysVinit)
```

These files are automatically removed by `./setup-zram.sh remove`.

## Examples

### Minimal system with 1GB RAM
```bash
# Automatically calculates 256MB zram (25% of 1GB)
sudo ./setup-zram.sh install
```

### Workstation with 16GB RAM
```bash
# Automatically calculates 6GB zram (capped)
sudo ./setup-zram.sh install
```

### Specific configuration for container
```bash
# Force exactly 2GB zram
ZRAM_SIZE_MB=2048 sudo ./setup-zram.sh install
```

### Temporary swap for build
```bash
# Install and check status
sudo ./setup-zram.sh install
sudo ./setup-zram.sh status

# After build, remove
sudo ./setup-zram.sh remove
```

## System Compatibility

### Tested On
- [ ] Debian 11, 12 (systemd)
- [ ] Ubuntu 20.04, 22.04, 24.04 (systemd)
- [x] Devuan 6 (SysVinit)
- [ ] Alpine Linux (OpenRC)
- [ ] Fedora 38+ (systemd)

### Kernel Requirements
- Linux 5.0+ recommended
- zram module must be loadable (`CONFIG_ZRAM=m`)

## Advanced Configuration

### Custom compression algorithm
After installation, change the algorithm:

```bash
# View available algorithms
cat /sys/block/zram0/comp_algorithm

# Switch to lzo
echo lzo | sudo tee /sys/block/zram0/comp_algorithm
```

### Memory limit
Prevent zram from using too much RAM:

```bash
# Limit to 1GB
echo 1G | sudo tee /sys/block/zram0/mem_limit
```

### Compression level
For algorithms that support it:

```bash
echo "level=5" | sudo tee /sys/block/zram0/algorithm_params
```

## Performance Tuning

### For maximum compression (slower decompression)
```bash
echo zstd | sudo tee /sys/block/zram0/comp_algorithm
echo "level=15" | sudo tee /sys/block/zram0/algorithm_params
```

### For maximum speed (lower compression)
```bash
echo lz4 | sudo tee /sys/block/zram0/comp_algorithm
```

### Monitor real-time stats
```bash
watch -n 1 'printf "Orig: %d MB | Compr: %d MB | Ratio: %.2f:1\n" \
  $(($(awk "{print \$1}" /sys/block/zram0/mm_stat)/1024)) \
  $(($(awk "{print \$2}" /sys/block/zram0/mm_stat)/1024)) \
  $(awk "{if(\$2>0) print \$1/\$2; else print 0}" /sys/block/zram0/mm_stat)'
```

## Contributing

To add support for additional init systems:

1. Add detection in `detect_init_system()`
2. Create appropriate init script generator function
3. Add case statement in `setup_persistence()`
4. Test on target system

## References

- [Linux zram kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/blockdev/zram.html)
- [zsmalloc memory allocator](https://www.kernel.org/doc/html/latest/vm/zsmalloc.html)
- [POSIX sh specification](https://pubs.opengroup.org/onlinepubs/9699919799/)

## Support

For issues or improvements:

1. Check troubleshooting section above
2. Review kernel logs: `dmesg | tail -50`
3. Verify zram module availability
4. Test with `ZRAM_SIZE_MB=512 sudo ./setup-zram.sh install`

## Author Notes

This script prioritizes portability and simplicity over advanced features. It creates persistent, automatic swap across diverse Linux distributions without external dependencies or complex configuration.

The smart sizing algorithm balances:
- **Small systems**: Preserve responsiveness, avoid memory exhaustion
- **Medium systems**: Maximize swap coverage for stability
- **Large systems**: Provide meaningful swap without waste

For production use, combine with proper swap monitoring and memory management policies.
