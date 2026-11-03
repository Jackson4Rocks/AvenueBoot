# AvenueBoot

```text
 █████╗ ██╗   ██╗███████╗███╗   ██╗██╗   ██╗███████╗██████╗  ██████╗  ██████╗ ████████╗
██╔══██╗██║   ██║██╔════╝████╗  ██║██║   ██║██╔════╝██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝
███████║██║   ██║█████╗  ██╔██╗ ██║██║   ██║█████╗  ██████╔╝██║   ██║██║   ██║   ██║
██╔══██║╚██╗ ██╔╝██╔══╝  ██║╚██╗██║██║   ██║██╔══╝  ██╔══██╗██║   ██║██║   ██║   ██║
██║  ██║ ╚████╔╝ ███████╗██║ ╚████║╚██████╔╝███████╗██████╔╝╚██████╔╝╚██████╔╝   ██║
╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═══╝ ╚═════╝ ╚══════╝╚═════╝  ╚═════╝  ╚═════╝    ╚═╝
```

Its a small tool that flashes Windows to a USB drive, using Linux.
This project was mostly made to flash Windows on Linux, cause that's mostly not easy to do soooo yeah....

> ### ⚠️ Windows ISOs only
> AvenueBoot **will only work with Windows installation ISOs** (Windows 8.1, 10, or 11, or any modded version of Windows really).
> A Linux ISO will not work, the script will refuse it, because it's built specifically for Windows media.
> For Linux ISOs, use something like `dd`, Etcher, or Ventoy instead.
> Future Support may include any ISO but that will be considered with the next version.

## What it does

- Wipes the USB drive you pick (⚠️ everything on it is gone)
- Creates one FAT32 partition — the layout Windows installers expect
- Copies all files from the Windows ISO to the USB drive
- If `install.wim` is bigger than 4 GB (common with Windows 11), it splits the file into smaller `.swm` pieces that both FAT32 and Windows Setup understand
- Ends with a drive that boots in **UEFI mode**

Note: it creates **UEFI-only** boot media. Old machines that only do legacy BIOS boot won't boot this USB. Almost any PC from the last ~10 years is fine. Unless it only has legacy and no UEFI.

## What you need

- A **Windows ISO** (take your pick), Linux ISOs don't work, see the warning above
- A USB drive with at least 8 GB free — **all data on it will be erased**
- A Linux machine with `sudo` (Ubuntu/Debian, Fedora, Arch, openSUSE, Alpine, Void, and Gentoo are all handled)

## How to use

```bash
git clone https://github.com/Jackson4Rocks/AvenueBoot ~/AvenueBoot
chmod +x AvenueBoot.sh
sudo ./AvenueBoot.sh
```

Then just follow the prompts:

1. **Pick your USB drive** from the list (checks the size and model so you don't nuke the wrong disk)
2. **Pick your Windows ISO** — it shows ISOs found in the current folder, or you can type a path
3. **Confirm the erase** by typing the device path exactly, e.g. `/dev/sdb` (by design — no accidents)

Or skip the prompts and do it in one line:

```bash
sudo ./AvenueBoot.sh --iso ~/Downloads/Win11.iso --device /dev/sdb
```

After it finishes, **safely eject the drive** before unplugging it.

## Options

```
-i, --iso FILE       Windows ISO to use
-d, --device DEVICE  Whole USB device (/dev/sdb — not /dev/sdb1)
-y, --yes            Skip all prompts (needs --iso and --device; automation only)
    --list-devices   Show connected drives and exit
    --dry-run        Run every check without touching any disk
-h, --help           Show help
```

## Is it safe?
Well, theres no guarantee about the safety of this, there are chances you can overwrite your Linux drive (the os your currently running), but other than that i would say its working as its supposed to.
The erase is real tho, there's no undo. But the script does protect you (kinda):

- **Refuses to erase** the disk your running Linux system is on (UNSTABLE, CANNOT BE TRUSTED TO DO SUCH)
- **Refuses to erase** the disk the ISO file itself is stored on (pointless and dangerous) (ALSO UNSTABLE, READ ABOVE)
- **Requires confirmation** — you must literally type the device path, unless you pass `--yes` (and even then you must have given both `--iso` and `--device` explicitly)
- **Warns clearly** before anything is wiped, listing exactly which ISO and which device
- Supports `--dry-run` to do all the checks with zero changes, so you can see what would happen

Missing dependencies (parted, dosfstools, rsync, wimtools, …) are detected automatically, and it offers to install them from your distro's package manager.

## Troubleshooting

| Message | What it means |
| --- | --- |
| "ISO does not look like Windows installation media" | The ISO isn't a Windows installer ISO. AvenueBoot only supports Windows ISOs. |
| "install.wim is larger than FAT32 permits" | Normal for Windows 11 ISOs — the script splits it into `.swm` files automatically. Nothing to do. |
| USB won't boot on another PC | Boot in UEFI mode (check the boot menu for "UEFI: <disk name>"). Legacy BIOS boot isn't supported. |
| "Root privileges are required" | Run it with `sudo`. |
| "Refusing to erase the disk containing the running system" | You picked your own system disk. Pick the actual USB drive instead. |

## FAQ

**Can I use this for my Linux ISO?** No. Windows ISOs only. The script specifically looks for and validates Windows installer structure (`/boot` + `/sources`), and it's designed around how Windows Setup media works.

**Why FAT32 and not NTFS or just dd the ISO?** FAT32 is what Windows UEFI boot expects out of the box. Copying files (instead of raw-imaging) means the USB stays usable and the big `install.wim` can simply be split to fit.

**BIOS/Legacy boot?** Not supported — UEFI only. That covers effectively all modern machines.
