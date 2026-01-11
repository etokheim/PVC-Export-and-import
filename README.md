# PVC Export & Import Scripts - Kubernetes Persistent Volume Backup Tool

Robust bash scripts for exporting and importing Kubernetes PersistentVolumeClaim (PVC) contents. Export to compressed tar.gz archives and import from folders, tar, or tar.gz files. Automatically detects and supports both MicroK8s and standard Kubernetes distributions.

I have used it successfully to export and import PVCs ranging from small to larger than a terabyte. Worked out great!

**Keywords**: Kubernetes backup, PVC export, PVC import, persistent volume backup, Kubernetes data export, MicroK8s backup, PVC backup script, Kubernetes volume export, persistent volume claim backup, k8s backup tool, container storage backup, Kubernetes data migration, PVC snapshot, volume backup automation, PVC restore

## Features

### Export Script (`pv-export.sh`)
- ✅ Export single or multiple PVCs in one command
- ✅ **Per-PVC namespace support** (`pvc@namespace` syntax)
- ✅ **Multiple export formats**: compressed (.tar.gz), uncompressed (.tar), or plain folder
- ✅ Custom output directory support
- ✅ Progress indication (with `pv` tool)
- ✅ Automatic pod cleanup
- ✅ ReadWriteOnce conflict detection
- ✅ Disk space checking
- ✅ Verbose/debug mode
- ✅ Non-interactive mode support (for automation)
- ✅ Comprehensive error handling
- ✅ Export summary with file sizes

### Import Script (`pv-import.sh`)
- ✅ Import from folders, tar, or tar.gz files
- ✅ Import multiple sources in one command
- ✅ Auto-detect namespace and PVC name from filename
- ✅ Create new PVCs if they don't exist
- ✅ Interactive storage class selection
- ✅ Merge or clear existing data options
- ✅ ReadWriteOnce conflict detection
- ✅ Archive validation before import
- ✅ Progress indication (with `pv` tool)
- ✅ Automatic pod cleanup
- ✅ Comprehensive logging

### Both Scripts
- ✅ Works with MicroK8s and standard Kubernetes
- ✅ Automated dependency checking and installation prompts
- ✅ Detailed logging to file
- ✅ Graceful interrupt handling (Ctrl+C)

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
  - The scripts automatically detect which one is available
- **Optional**: `pv` (pipe viewer) for better progress indication
  - Ubuntu/Debian: `sudo apt-get install pv`
  - macOS: `brew install pv`

### Permissions

- Write access to the output directory (export) or source files (import)
- Kubernetes cluster access via `kubectl` or `microk8s kubectl`
- Permission to create and delete pods in the target namespace
- Permission to create PVCs (for import with new PVC creation)
- Valid kubeconfig configured (for standard kubectl)

## Installation

1. Download the scripts:
   ```bash
   wget https://your-repo/pv-export.sh
   wget https://your-repo/pv-import.sh
   # or
   curl -O https://your-repo/pv-export.sh
   curl -O https://your-repo/pv-import.sh
   ```

2. Make them executable:
   ```bash
   chmod +x pv-export.sh pv-import.sh
   ```

3. (Optional) Add to PATH:
   ```bash
   sudo mv pv-export.sh /usr/local/bin/pv-export
   sudo mv pv-import.sh /usr/local/bin/pv-import
   ```

---

## Export Script Usage

### Basic Export Usage

```bash
# Export a single PVC from default namespace
./pv-export.sh my-pvc

# Export multiple PVCs
./pv-export.sh pvc1 pvc2 pvc3

# Export with custom namespace (applies to all PVCs)
./pv-export.sh -n production my-pvc

# Export with per-PVC namespace using @ syntax
./pv-export.sh my-pvc@production

# Export PVCs from different namespaces in one command
./pv-export.sh pvc1@namespace1 pvc2@namespace2 pvc3@namespace3

# Mix default namespace and per-PVC namespace
./pv-export.sh -n staging pvc1 pvc2@production pvc3
# pvc1 uses 'staging', pvc2 uses 'production', pvc3 uses 'staging'

# Export to specific directory
./pv-export.sh -o /backup/my-exports my-pvc

# Combine options
./pv-export.sh -n production -o /mnt/external pvc1 pvc2 pvc3
```

### Export Command-Line Options

| Option | Long Form | Description | Default |
|--------|-----------|-------------|---------|
| `-n` | `--namespace` | Default Kubernetes namespace for PVCs without `@namespace` | `default` |
| `-o` | `--output` | Output directory for exported files | Current directory |
| `-v` | `--verbose` | Enable verbose/debug output | Disabled |
| | `--uncompressed` | Use uncompressed tar (faster, less memory, larger files)<br>Recommended for very large PVCs (>1TB) | Disabled |
| | `--folder` | Export to plain folder (no archive, uses kubectl cp)<br>Best for quick access to files without extraction | Disabled |
| `-V` | `--version` | Show version information | - |
| `-h` | `--help` | Show help message | - |

### PVC Naming with Namespaces

You can specify the namespace per-PVC using the `@namespace` suffix:

| Format | Description |
|--------|-------------|
| `pvc-name` | Uses the default namespace (`-n` option or `default`) |
| `pvc-name@namespace` | Uses the specified namespace |

This allows you to export PVCs from multiple namespaces in a single command.

### Export Examples

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

#### Export to Plain Folder

For quick access to files without needing to extract an archive:

```bash
./pv-export.sh --folder -o /mnt/external my-pvc
```

This creates a folder `my-pvc/` containing all the files from the PVC. Useful when you need to browse or access individual files immediately.

#### Export from Different Namespace

```bash
# Using -n flag (all PVCs use the same namespace)
./pv-export.sh -n production app-data user-data
```

#### Export from Multiple Namespaces

```bash
# Using @ syntax to specify namespace per-PVC
./pv-export.sh database@production cache@staging logs@monitoring

# Mix: some PVCs use default namespace, others specify their own
./pv-export.sh -n production app-data user-data config@staging
# app-data and user-data use 'production', config uses 'staging'
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

---

## Import Script Usage

### Basic Import Usage

```bash
# Import from a tar.gz archive (exported by pv-export.sh)
./pv-import.sh ./default-my-pvc.tar.gz

# Import from multiple sources
./pv-import.sh backup1.tar.gz backup2.tar.gz backup3/

# Import from a folder
./pv-import.sh ./my-backup-folder

# Import from an uncompressed tar
./pv-import.sh ./default-my-pvc.tar
```

### Import Command-Line Options

| Option | Long Form | Description | Default |
|--------|-----------|-------------|---------|
| `-v` | `--verbose` | Enable verbose/debug output | Disabled |
| `-V` | `--version` | Show version information | - |
| `-h` | `--help` | Show help message | - |

### Interactive Prompts

The import script is fully interactive and will prompt for:

1. **Target Namespace** - Select from available namespaces or create a new one
2. **Target PVC** - Enter PVC name; if it doesn't exist, you can create it
3. **Storage Class** - Select from available storage classes (for new PVCs)
4. **PVC Size** - Suggested based on source size with 20% padding (for new PVCs)
5. **Data Handling** - Merge with existing data or clear first

### Import Examples

#### Import Exported Archive

```bash
./pv-import.sh ./default-unifi.tar.gz
```

The script will:
1. Detect it's a tar.gz file
2. Parse `default-unifi` to suggest namespace `default` and PVC `unifi`
3. Prompt for confirmation or changes
4. Import the data

#### Import Multiple Archives

```bash
./pv-import.sh production-db.tar.gz production-cache.tar.gz
```

For each archive, you'll be prompted for target configuration.

#### Import to New PVC

If the target PVC doesn't exist:

```bash
./pv-import.sh ./backup-data.tar.gz
```

The script will prompt:
```
⚠️  PVC 'backup-data' does not exist in namespace 'default'
Create new PVC? (Y/n): y

📀 Select storage class:
  1) standard (default)
  2) fast-ssd
  3) nfs-storage

Storage class [standard]: 2
✓ Storage class: fast-ssd

PVC size [5Gi]: 10Gi
✓ PVC size: 10Gi
```

#### Import from Folder

```bash
./pv-import.sh /path/to/backup/folder
```

Copies all contents recursively while preserving permissions.

#### Data Handling Options

When importing to an existing PVC with data:

```
📋 Data handling for default/my-pvc:
   1) Merge - Add files without removing existing data
   2) Clear - Remove all existing data before import

Select option [1]: 
```

### Import Workflow

1. **Source Validation** - Checks all sources exist and are valid
2. **Target Configuration** - Interactive prompts for each source
3. **Conflict Detection** - Checks for ReadWriteOnce conflicts
4. **Archive Validation** - Validates tar archives are not corrupted
5. **Confirmation** - Shows summary and asks for confirmation
6. **Import Execution** - Creates pods, imports data, cleans up
7. **Verification** - Shows imported data size and file count

---

## How It Works

### Export Process

1. **Validation**: Checks dependencies, PVC existence, and output directory permissions
2. **Pod Creation**: Creates a temporary busybox pod with the PVC mounted
3. **Export**: Uses `tar` to compress and export the PVC contents
4. **Cleanup**: Automatically deletes the temporary pod
5. **Verification**: Validates the exported archive and shows summary

### Import Process

1. **Source Detection**: Identifies source type (folder, tar, tar.gz)
2. **Configuration**: Collects all user input before starting imports
3. **Validation**: Validates all sources and checks for conflicts
4. **Namespace/PVC Creation**: Creates namespace and PVC if needed
5. **Pod Creation**: Creates a temporary busybox pod with the PVC mounted
6. **Data Clearing**: Optionally clears existing data
7. **Import**: Streams data into the pod using tar
8. **Verification**: Shows imported data size and file count
9. **Cleanup**: Automatically deletes the temporary pod

**Perfect for**: Kubernetes backup strategies, PVC migration, persistent volume export/import, container data backup, Kubernetes disaster recovery, volume snapshot alternatives

## Output Files

Exported files are named using the pattern:
```
{namespace}-{pvc-name}.tar.gz
```

For example:
- PVC `unifi` in namespace `default` → `default-unifi.tar.gz`
- PVC `database` in namespace `production` → `production-database.tar.gz`

Special characters in PVC names are sanitized (replaced with underscores) for filesystem compatibility.

The import script recognizes this naming pattern and automatically suggests the correct namespace and PVC name.

## Logging

Both scripts create detailed logs in the `logs/` directory:

```
logs/
├── pv-export-20240115-143052.log
├── pv-import-20240115-150123.log
└── pod_logs/
    └── default-my-pvc-export-pod-20240115-143052.log
```

Logs include:
- Timestamps for all operations
- Command output
- Pod descriptions and events (on failure)
- Container logs

## Troubleshooting

Common issues when performing Kubernetes PVC backups and persistent volume exports:

### PVC Not Found

```
❌ Error: PVC 'my-pvc' not found in namespace 'default'
```

**Solutions:**
- Verify the PVC name: `kubectl get pvc -n <namespace>`
- Check the namespace: `kubectl get namespaces`
- Ensure you have the correct permissions
- Verify kubeconfig is configured: `kubectl config view`

### Pod Stuck in "ContainerCreating"

This usually means the PVC is already mounted by another pod (ReadWriteOnce limitation).

**Solutions:**
- Stop the pod using the PVC temporarily
- Use a different backup method
- The scripts will warn you and ask for confirmation

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

### Export/Import Fails Silently

Enable verbose mode to see detailed information:
```bash
./pv-export.sh -v my-pvc
./pv-import.sh -v backup.tar.gz
```

### Permission Denied

Ensure you have:
- Write permissions to the output directory
- Kubernetes permissions to create/delete pods
- Kubernetes permissions to create PVCs (for import)
- Access to the target namespace
- Valid kubeconfig: `kubectl cluster-info`

### Export Fails with Exit Code 137 (OOM Kill)

If you see "command terminated with exit code 137" when exporting large PVCs, the pod ran out of memory.

**Solutions:**
- The script automatically increases memory limits for large PVCs (up to 16Gi for >1TB)
- For very large PVCs (>1TB), use the `--uncompressed` flag:
  ```bash
  ./pv-export.sh --uncompressed -o /mnt/external my-large-pvc
  ```
- Check pod resource usage: `kubectl top pod <pod-name> -n <namespace>`
- Ensure your cluster has sufficient resources available

### Archive Validation Failed

```
❌ Archive is corrupted or invalid
```

**Solutions:**
- Verify the archive: `tar -tzf backup.tar.gz`
- Re-export the PVC
- Check for disk errors during export

### kubectl Not Detected

The scripts automatically detect `microk8s kubectl` or standard `kubectl`. If neither is found:

**For MicroK8s:**
```bash
microk8s status
microk8s kubectl get nodes
```

**For Standard Kubernetes:**
```bash
kubectl version --client
kubectl cluster-info
kubectl config view
```

## Limitations

1. **ReadWriteOnce PVCs**: Can only be mounted by one pod at a time. The scripts detect this and warn you.
2. **Storage Class**: Some storage classes may have restrictions on pod mounting.
3. **Large PVCs**: Very large PVCs (>100GB) may take significant time. The export script automatically adjusts memory limits:
   - Default: 2Gi for small PVCs
   - 4Gi for PVCs >100Gi
   - 8Gi for PVCs >500Gi
   - 16Gi for PVCs >1TB
   - For PVCs >1TB, consider using `--uncompressed` flag
4. **Network Storage**: Performance depends on your storage backend.
5. **Import Script**: Requires interactive terminal (no non-interactive mode yet)

## Best Practices

Follow these Kubernetes backup best practices for reliable PVC exports:

1. **Regular Backups**: Schedule regular exports using cron
2. **Test Restores**: Periodically test importing from backups
3. **Monitor Space**: Ensure adequate disk space before large exports
4. **Use Verbose Mode**: When troubleshooting, use `-v` flag
5. **Document Namespaces**: Keep track of which PVCs are in which namespaces
6. **Backup Strategy**: Implement a comprehensive Kubernetes backup strategy
7. **Volume Migration**: Use for safe persistent volume migration between clusters
8. **Verify Imports**: Check data size and file count after import

## Example Cron Job

Automated Kubernetes backup scheduling example:

```bash
# Backup all PVCs daily at 2 AM
0 2 * * * /usr/local/bin/pv-export -o /backup/daily pvc1 pvc2 pvc3 >> /var/log/pvc-backup.log 2>&1
```

## Exit Codes

### Export Script
- `0` - Success (all exports completed)
- `1` - Error (one or more exports failed, or invalid arguments)
- `130` - Interrupted (Ctrl+C)

### Import Script
- `0` - Success (all imports completed)
- `1` - Error (one or more imports failed, or invalid arguments)
- `130` - Interrupted (Ctrl+C)

## Version

- **pv-export.sh**: Version 2.2
- **pv-import.sh**: Version 1.0

## License

These scripts are provided as-is for use with Kubernetes/MicroK8s environments.

## Contributing

Issues and improvements are welcome! Please ensure:
- Scripts remain compatible with MicroK8s and standard Kubernetes
- Scripts work on both Linux and macOS
- Error handling is maintained
- Code follows bash best practices

## Support

For issues or questions:
1. Check the troubleshooting section
2. Run with `-v` flag for verbose output
3. Check the log files in `logs/` directory
4. Check Kubernetes pod events: `kubectl get events -n <namespace>`

## Changelog

### pv-export.sh - Version 2.2
- **NEW**: Export to plain folder with `--folder` flag
- Interactive format selection: compressed (.tar.gz), uncompressed (.tar), or folder
- Uses kubectl cp for folder exports for faster file access

### pv-export.sh - Version 2.1
- **NEW**: Per-PVC namespace support using `pvc@namespace` syntax
- Export PVCs from multiple namespaces in a single command
- `-n` flag now sets the default namespace for PVCs without `@namespace`

### pv-export.sh - Version 2.0
- Added support for multiple PVC exports
- Added output directory option
- Added verbose mode
- Added `--uncompressed` option for large PVCs
- Improved error handling
- Added non-interactive mode support
- Better cleanup handling
- Enhanced progress indication
- Comprehensive logging

### pv-import.sh - Version 1.0
- Initial release
- Support for folder, tar, and tar.gz sources
- Interactive PVC and namespace selection
- Create new PVCs with storage class selection
- Merge or clear existing data options
- Archive validation
- ReadWriteOnce conflict detection
- Comprehensive logging

## Related Topics

- **Kubernetes Backup Solutions**: These scripts provide a lightweight alternative to enterprise backup tools
- **PVC Migration**: Use for migrating persistent volumes between Kubernetes clusters
- **Disaster Recovery**: Essential tools for Kubernetes disaster recovery planning
- **Volume Snapshots**: Alternative to CSI volume snapshots for simple backup needs
- **Container Data Backup**: Backup and restore data from containerized applications
- **MicroK8s Backup**: Specifically optimized for MicroK8s environments
- **Kubernetes Data Export/Import**: Export and import persistent volume data for analysis or migration

## Search Terms

People searching for these terms will find these tools useful:
- Kubernetes PVC backup
- Kubernetes PVC restore
- Persistent volume export script
- Persistent volume import script
- Kubernetes volume backup tool
- PVC data migration
- Kubernetes backup automation
- MicroK8s backup script
- Container storage backup
- Kubernetes disaster recovery
- Persistent volume claim export
- Persistent volume claim import
- K8s backup solution
- Kubernetes data export tool
- Kubernetes data import tool
- PVC snapshot alternative

---

**Note**: The scripts automatically detect whether to use `microk8s kubectl` or standard `kubectl`. They prefer MicroK8s if available, otherwise fall back to standard kubectl. No manual configuration needed!

**Perfect for**: Kubernetes administrators, DevOps engineers, SRE teams, and anyone needing reliable PVC backup, export, and import capabilities.
