# PVC Export Script - Kubernetes Persistent Volume Backup Tool

A robust bash script for exporting Kubernetes PersistentVolumeClaim (PVC) contents to compressed tar.gz archives. Automatically detects and supports both MicroK8s and standard Kubernetes distributions.

I have used it successfully to export PVCs ranging from small to larger than a terabyte. Worked out great!

**Keywords**: Kubernetes backup, PVC export, persistent volume backup, Kubernetes data export, MicroK8s backup, PVC backup script, Kubernetes volume export, persistent volume claim backup, k8s backup tool, container storage backup, Kubernetes data migration, PVC snapshot, volume backup automation

## Features

- ✅ Export single or multiple PVCs in one command
- ✅ Custom output directory support
- ✅ Progress indication (with `pv` tool)
- ✅ Automatic pod cleanup
- ✅ ReadWriteOnce conflict detection
- ✅ Disk space checking
- ✅ Verbose/debug mode
- ✅ Non-interactive mode support (for automation)
- ✅ Comprehensive error handling
- ✅ Export summary with file sizes
- ✅ Works with MicroK8s and standard Kubernetes
- ✅ Automated Kubernetes volume backup
- ✅ PVC data migration tool

## Requirements

### Dependencies

- **bash** (version 4.0+)
- **jq** - JSON processor
  - Ubuntu/Debian: `sudo apt-get install jq`
  - macOS: `brew install jq`
  - Fedora: `sudo dnf install jq`
- **kubectl** - Kubernetes command-line tool
  - **Option 1**: MicroK8s (`microk8s kubectl`)
    - See: https://microk8s.io/docs/getting-started
  - **Option 2**: Standard kubectl
    - See: https://kubernetes.io/docs/tasks/tools/
  - The script automatically detects which one is available
- **Optional**: `pv` (pipe viewer) for better progress indication
  - Ubuntu/Debian: `sudo apt-get install pv`
  - macOS: `brew install pv`

### Permissions

- Write access to the output directory
- Kubernetes cluster access via `kubectl` or `microk8s kubectl`
- Permission to create and delete pods in the target namespace
- Valid kubeconfig configured (for standard kubectl)

## Installation

1. Download the script:
   ```bash
   wget https://your-repo/pv-export.sh
   # or
   curl -O https://your-repo/pv-export.sh
   ```

2. Make it executable:
   ```bash
   chmod +x pv-export.sh
   ```

3. (Optional) Add to PATH:
   ```bash
   sudo mv pv-export.sh /usr/local/bin/pv-export
   ```

## Usage

### Basic Usage

```bash
# Export a single PVC from default namespace
./pv-export.sh my-pvc

# Export multiple PVCs
./pv-export.sh pvc1 pvc2 pvc3

# Export with custom namespace
./pv-export.sh -n production my-pvc

# Export to specific directory
./pv-export.sh -o /backup/my-exports my-pvc

# Combine options
./pv-export.sh -n production -o /mnt/external pvc1 pvc2 pvc3
```

### Command-Line Options

| Option | Long Form | Description | Default |
|--------|-----------|-------------|---------|
| `-n` | `--namespace` | Kubernetes namespace | `default` |
| `-o` | `--output` | Output directory for exported files | Current directory |
| `-v` | `--verbose` | Enable verbose/debug output | Disabled |
| | `--uncompressed` | Use uncompressed tar (faster, less memory, larger files)<br>Recommended for very large PVCs (>1TB) | Disabled |
| `-V` | `--version` | Show version information | - |
| `-h` | `--help` | Show help message | - |

### Examples

#### Export Single PVC

```bash
./pv-export.sh unifi
```

Output: `default-unifi.tar.gz`

#### Export Multiple PVCs

```bash
./pv-export.sh database cache redis
```

Outputs:
- `default-database.tar.gz`
- `default-cache.tar.gz`
- `default-redis.tar.gz`

#### Export to External Drive

```bash
./pv-export.sh -o /mnt/usb-drive/backups pvc1 pvc2
```

#### Export Very Large PVCs (>1TB) Without Compression

For extremely large PVCs, use the `--uncompressed` flag to reduce memory usage and speed up the export:

```bash
./pv-export.sh --uncompressed -o /mnt/external my-1.5tb-pvc
```

This creates a `.tar` file instead of `.tar.gz`. The export will be faster and use less memory, but the output file will be larger.

#### Export from Different Namespace

```bash
./pv-export.sh -n production app-data user-data
```

#### Verbose Mode

```bash
./pv-export.sh -v my-pvc
```

Shows detailed debug information including pod creation, status checks, and cleanup operations.

#### Non-Interactive Mode

The script automatically detects non-interactive environments (like cron jobs) and skips prompts:

```bash
# In cron or script
0 2 * * * /path/to/pv-export.sh -o /backup my-pvc
```

## How It Works

The script performs automated Kubernetes persistent volume backup through the following process:

1. **Validation**: Checks dependencies, PVC existence, and output directory permissions
2. **Pod Creation**: Creates a temporary busybox pod with the PVC mounted
3. **Export**: Uses `tar` to compress and export the PVC contents (Kubernetes volume backup)
4. **Cleanup**: Automatically deletes the temporary pod
5. **Verification**: Validates the exported archive and shows summary

**Perfect for**: Kubernetes backup strategies, PVC migration, persistent volume export, container data backup, Kubernetes disaster recovery, volume snapshot alternatives

## Output Files

Exported files are named using the pattern:
```
{namespace}-{pvc-name}.tar.gz
```

For example:
- PVC `unifi` in namespace `default` → `default-unifi.tar.gz`
- PVC `database` in namespace `production` → `production-database.tar.gz`

Special characters in PVC names are sanitized (replaced with underscores) for filesystem compatibility.

## Restoring Exports

To restore an exported PVC (Kubernetes volume restore):

```bash
# Extract the archive
tar -xzf default-unifi.tar.gz

# Or extract to a specific directory
tar -xzf default-unifi.tar.gz -C /restore/path
```

**Restoration Use Cases**: Kubernetes data recovery, PVC restore, persistent volume migration, container data restoration, Kubernetes backup restore

## Troubleshooting

Common issues when performing Kubernetes PVC backups and persistent volume exports:

### PVC Not Found

```
❌ Error: PVC 'my-pvc' not found in namespace 'default'
```

**Solutions:**
- Verify the PVC name: `kubectl get pvc -n <namespace>` (or `microk8s kubectl get pvc -n <namespace>`)
- Check the namespace: `kubectl get namespaces` (or `microk8s kubectl get namespaces`)
- Ensure you have the correct permissions
- Verify kubeconfig is configured (for standard kubectl): `kubectl config view`

### Pod Stuck in "ContainerCreating"

This usually means the PVC is already mounted by another pod (ReadWriteOnce limitation).

**Solutions:**
- Stop the pod using the PVC temporarily
- Use a different backup method
- The script will warn you and ask for confirmation

### Cannot Write to Output Directory

```
❌ Error: Cannot write to output directory: /backup
```

**Solutions:**
- Check directory permissions: `ls -ld /backup`
- Ensure the directory exists or the script can create it
- Check available disk space: `df -h /backup`

### Low Disk Space Warning

The script warns if less than 1GB is available. Ensure you have enough space for:
- The compressed export (usually 30-70% of PVC size)
- Temporary files during export

### Export Fails Silently

Enable verbose mode to see detailed information:
```bash
./pv-export.sh -v my-pvc
```

### Permission Denied

Ensure you have:
- Write permissions to the output directory
- Kubernetes permissions to create/delete pods
- Access to the target namespace
- Valid kubeconfig (for standard kubectl): `kubectl cluster-info`

### Export Fails with Exit Code 137 (OOM Kill)

If you see "command terminated with exit code 137" when exporting large PVCs, the pod ran out of memory.

**Solutions:**
- The script automatically increases memory limits for large PVCs (up to 16Gi for >1TB)
- For very large PVCs (>1TB), use the `--uncompressed` flag to reduce memory usage:
  ```bash
  ./pv-export.sh --uncompressed -o /mnt/external my-large-pvc
  ```
- Check pod resource usage: `kubectl top pod <pod-name> -n <namespace>`
- Ensure your cluster has sufficient resources available

### kubectl Not Detected

The script automatically detects `microk8s kubectl` or standard `kubectl`. If neither is found:

**For MicroK8s:**
```bash
# Verify microk8s is installed
microk8s status

# Verify kubectl access
microk8s kubectl get nodes
```

**For Standard Kubernetes:**
```bash
# Verify kubectl is installed
kubectl version --client

# Verify cluster access
kubectl cluster-info

# Check kubeconfig
kubectl config view
```

## Limitations

1. **ReadWriteOnce PVCs**: Can only be mounted by one pod at a time. The script detects this and warns you.
2. **Storage Class**: Some storage classes may have restrictions on pod mounting.
3. **Large PVCs**: Very large PVCs (>100GB) may take significant time to export. The script automatically adjusts memory limits:
   - Default: 2Gi for small PVCs
   - 4Gi for PVCs >100Gi
   - 8Gi for PVCs >500Gi
   - 16Gi for PVCs >1TB
   - For PVCs >1TB, consider using `--uncompressed` flag for better performance
4. **Network Storage**: Performance depends on your storage backend.

## Best Practices

Follow these Kubernetes backup best practices for reliable PVC exports:

1. **Regular Backups**: Schedule regular exports using cron (Kubernetes backup automation)
2. **Test Restores**: Periodically test restoring from backups (disaster recovery testing)
3. **Monitor Space**: Ensure adequate disk space before large exports
4. **Use Verbose Mode**: When troubleshooting, use `-v` flag
5. **Document Namespaces**: Keep track of which PVCs are in which namespaces
6. **Backup Strategy**: Implement a comprehensive Kubernetes backup strategy
7. **Volume Migration**: Use for safe persistent volume migration between clusters

## Example Cron Job

Automated Kubernetes backup scheduling example:

```bash
# Backup all PVCs daily at 2 AM (Kubernetes automated backup)
0 2 * * * /usr/local/bin/pv-export.sh -o /backup/daily pvc1 pvc2 pvc3 >> /var/log/pvc-backup.log 2>&1
```

**Automation Benefits**: Scheduled Kubernetes backups, automated PVC exports, persistent volume backup automation, container storage backup scheduling

## Exit Codes

- `0` - Success (all exports completed)
- `1` - Error (one or more exports failed, or invalid arguments)

## Version

Current version: **2.0**

## License

This script is provided as-is for use with Kubernetes/MicroK8s environments.

## Contributing

Issues and improvements are welcome! Please ensure:
- Script remains compatible with MicroK8s
- Error handling is maintained
- Code follows bash best practices

## Support

For issues or questions:
1. Check the troubleshooting section
2. Run with `-v` flag for verbose output
3. Check Kubernetes pod events: `microk8s kubectl get events -n <namespace>`

## Changelog

### Version 2.0
- Added support for multiple PVC exports
- Added output directory option
- Added verbose mode
- Improved error handling
- Added non-interactive mode support
- Better cleanup handling
- Enhanced progress indication

## Related Topics

- **Kubernetes Backup Solutions**: This script provides a lightweight alternative to enterprise backup tools
- **PVC Migration**: Use for migrating persistent volumes between Kubernetes clusters
- **Disaster Recovery**: Essential tool for Kubernetes disaster recovery planning
- **Volume Snapshots**: Alternative to CSI volume snapshots for simple backup needs
- **Container Data Backup**: Backup data from containerized applications running on Kubernetes
- **MicroK8s Backup**: Specifically optimized for MicroK8s environments
- **Kubernetes Data Export**: Export persistent volume data for analysis or migration

## Search Terms

People searching for these terms will find this tool useful:
- Kubernetes PVC backup
- Persistent volume export script
- Kubernetes volume backup tool
- PVC data migration
- Kubernetes backup automation
- MicroK8s backup script
- Container storage backup
- Kubernetes disaster recovery
- Persistent volume claim export
- K8s backup solution
- Kubernetes data export tool
- PVC snapshot alternative

---

**Note**: The script automatically detects whether to use `microk8s kubectl` or standard `kubectl`. It will prefer MicroK8s if available, otherwise falls back to standard kubectl. No manual configuration needed!

**Perfect for**: Kubernetes administrators, DevOps engineers, SRE teams, and anyone needing reliable PVC backup and export capabilities.

