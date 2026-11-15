#!/bin/zsh
# 660m-Metal installer: README step 8 ("Turn on acceleration") and step 10 ("After it works"), done for you.
#
# Double-click it in Finder, or run it in Terminal:   zsh install.command
#
# What it does, in order:
#   1. Checks macOS (must be 25G229), finds the Radeon 660M and its PCI path, checks the kext fits.
#   2. Finds the EFI partition OpenCore booted from and mounts it.
#   3. Backs up that whole EFI folder to ~/Documents/660m-EFI-backups (checked with SHA-256).
#   4. Installs on a USB test stick (recommended first) or on the internal EFI:
#      copies Rembrandt660M.kext, registers it directly after Lilu, adds the GPU's DeviceProperties,
#      adds -lilubetaall -rmbumd to boot-args, checks config.plist with plutil.
#   5. After a successful boot: video decode, sleep off, macOS updates off (step 10).
#
# It never touches SIP, NVRAM, PlatformInfo (your serials) or anything outside the EFI folder it installs to.
# Options:  --kext <path>  use your own build (README step 7) instead of dist/Rembrandt660M.kext
#           --efi <dir>    patch this EFI folder in place (advanced; it is still backed up first)

emulate -L zsh
setopt pipe_fail no_nomatch
autoload -Uz is-at-least

REPO=${0:A:h}
KEXT=$REPO/dist/Rembrandt660M.kext
EFI_ARG=""
NEED_BUILD=25G229
GUID=7C436110-AB2A-4BBB-A880-FE41995C9F82
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUPS=${RMB_EFI_BACKUPS:-$HOME/Documents/660m-EFI-backups}

while (( $# )); do
	case $1 in
		--kext) KEXT=${2:A}; shift 2 ;;
		--efi) EFI_ARG=${2:A}; shift 2 ;;
		-h|--help) sed -n '2,20p' $0; exit 0 ;;
		*) print "Unknown option $1 (try --help)"; exit 2 ;;
	esac
done

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B= G= Y= R= N=; fi
say()  { print -r -- "$*"; }
ok()   { print -r -- "${G}  OK${N}  $*"; }
warn() { print -r -- "${Y}WARN${N}  $*"; }
die()  { print -r -- "${R}STOP${N}  $*"; print; print "Nothing was changed after this point."; finish 1; }
finish() { print; [[ -t 0 ]] && read -r "?Press Return to close. " ; exit ${1:-0}; }
ask()  { local a; read -r "a?$1 " ; print -r -- $a; }
yes()  { [[ $(ask "$1 [y/N]") == [yY]* ]]; }
# Writes into a mounted EFI may need root; try as the user first.
w()    { "$@" 2>/dev/null || sudo "$@"; }

# Sorted SHA-256 list of every file under $1 (relative paths).
manifest() { (cd "$1" && find . -type f ! -name '._*' ! -name '.DS_Store' -print0 | sort -z | xargs -0 shasum -a 256); }

# Copies folder $1 to $2 (must not exist) and checks every file's hash.
copy_verified() {
	w cp -R -X "$1" "$2" || return 1
	[[ "$(manifest "$1")" == "$(manifest "$2")" ]]
}

hexle() { local h=${1//[<>\"]/}; print -r -- ${h[3,4]}${h[1,2]}; }  # <aa170000> -> 17aa

# --- 1. checks ---------------------------------------------------------------------------------------------
say "${B}660m-Metal installer${N}"
say
say "${B}1. Checking this Mac${N}"

build=$(sw_vers -buildVersion)
[[ $build == $NEED_BUILD ]] || die "macOS build is $build, the kext only works on $NEED_BUILD (README step 5)."
ok "macOS $(sw_vers -productVersion) build $build"

gpu=$(ioreg -r -c IOPCIDevice -l -w0 -d1 | awk '
	function emit() { if (!done && v == "<02100000>" && (d == "<81160000>" || d == "<ff730000>")) { print a "|" sv "|" ss "|" rv "|" d; done = 1 } }
	/^\+-o/ { emit(); v = d = a = sv = ss = rv = "" }
	/"vendor-id" =/ { v = $NF } /"device-id" =/ { d = $NF } /"acpi-path" =/ { a = $NF }
	/"subsystem-vendor-id" =/ { sv = $NF } /"subsystem-id" =/ { ss = $NF } /"revision-id" =/ { rv = $NF }
	END { emit() }')
[[ -n $gpu ]] || die "No Radeon 660M (PCI 1002:1681) found. This kext is only for that GPU (README step 1)."
IFS='|' read -r acpi sv ss rv did <<< "$gpu"
acpi=${acpi//\"/}
subsys="$(hexle $sv):$(hexle $ss)"; rev=${${rv//[<>]/}[1,2]}
ok "Radeon 660M found, subsystem $subsys, revision $rev"

# IOACPIPlane:/_SB/PCI0@0/GP17@80001/VGA@0  ->  PciRoot(0x0)/Pci(0x8,0x1)/Pci(0x0,0x0)
devpath=""
if [[ $acpi == IOACPIPlane:/_SB/* ]]; then
	first=1
	for comp in ${(s:/:)${acpi#IOACPIPlane:/_SB/}}; do
		[[ $comp == *@* ]] || { devpath=""; break; }
		n=$(( 16#${comp#*@} ))
		if (( first )); then devpath=$(printf 'PciRoot(0x%x)' $n); first=0
		else devpath+=$(printf '/Pci(0x%x,0x%x)' $(( n >> 16 )) $(( n & 0xffff ))); fi
	done
fi
[[ -n $devpath ]] || die "Could not work out the GPU's PCI path. Find it with gfxutil (README step 8.4) and add the DeviceProperties by hand."
ok "GPU path $devpath"

[[ -f $KEXT/Contents/MacOS/Rembrandt660M ]] || die "Kext not found: $KEXT"
if [[ $KEXT == $REPO/dist/Rembrandt660M.kext ]]; then
	if [[ $subsys != 17aa:3b1e || $rev != 03 ]]; then
		die "The ready-made kext in dist/ only fits the Lenovo 82TL VBIOS (subsystem 17aa:3b1e, revision 03).
      Yours is $subsys revision $rev: build your own kext (README steps 3, 4 and 7), then run
      zsh install.command --kext <path to your Rembrandt660M.kext>"
	fi
	ok "dist/Rembrandt660M.kext fits this laptop's IDs (the kext still checks the VBIOS itself at boot)"
else
	ok "Using your own kext: $KEXT"
fi
kexthash=$(shasum -a 256 $KEXT/Contents/MacOS/Rembrandt660M | cut -c1-8)

loaded=$(kmutil showloaded --list-only 2>/dev/null | grep -c org.rembrandt660m.restore)
if (( loaded )); then ok "Rembrandt660M is already running (acceleration is on)"; fi

# --- step 10 -----------------------------------------------------------------------------------------------
finish_setup() {
	say; say "${B}Finish setup (README step 10)${N}"
	(( loaded )) || die "Rembrandt660M is not running yet. Install it and reboot first."
	metal=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -m1 'Metal Support' | sed 's/.*: //')
	ok "Metal: ${metal:-unknown}"
	say "This will:"
	say "  - let videos use the GPU (com.apple.AppleGVA, undo: defaults delete com.apple.AppleGVA)"
	say "  - turn off sleep, which doesn't work with this kext (pmset sleep 0; the screen still turns off)"
	say "  - turn off automatic macOS updates (an update to anything newer than $NEED_BUILD breaks the kext)"
	yes "Do it?" || finish 0
	defaults write com.apple.AppleGVA gvaForceAMDAVCDecode -bool YES && defaults write com.apple.AppleGVA gvaForceAMDHEVCDecode -bool YES && ok "Video decode on"
	say "Your password is needed for the next two:"
	sudo pmset -a sleep 0 && ok "Sleep off"
	sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false &&
		sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false &&
		sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false &&
		ok "Automatic macOS updates off. Never click \"Update Now\" in Software Update."
	say; say "Last step: remove -v from boot-args when everything works (README step 10.3)."
	finish 0
}

# --- patch one EFI folder ----------------------------------------------------------------------------------
patch_efi() {
	local T=$1 cfg=$1/OC/config.plist stage changes=()
	[[ -f $cfg ]] || die "No OC/config.plist in $T"
	plutil -lint -s $cfg || die "$cfg is not a valid plist. Fix it before installing."
	stage=$(mktemp -d)/config.plist; cp $cfg $stage

	# Lilu
	[[ -d $T/OC/Kexts/Lilu.kext ]] || die "Lilu.kext is not in $T/OC/Kexts (README step 6)."
	local lv=$(plutil -extract CFBundleVersion raw $T/OC/Kexts/Lilu.kext/Contents/Info.plist 2>/dev/null)
	is-at-least 1.7.2 ${lv:-0} || die "Lilu $lv is too old, 1.7.2 or newer is needed."

	# Kernel -> Add: no other graphics kext, Rembrandt660M directly after Lilu.
	local count=$(plutil -extract Kernel.Add raw $stage 2>/dev/null) i bp en lilu=-1 rmb=-1
	[[ $count == <-> ]] || die "config.plist has no Kernel -> Add array."
	for (( i = 0; i < count; i++ )); do
		bp=$(plutil -extract Kernel.Add.$i.BundlePath raw $stage 2>/dev/null)
		en=$(plutil -extract Kernel.Add.$i.Enabled raw $stage 2>/dev/null)
		case $bp in
			Lilu.kext) lilu=$i ;;
			Rembrandt660M.kext) rmb=$i ;;
			NootedRed.kext|WhateverGreen.kext)
				[[ $en == true ]] && die "$bp is enabled in Kernel -> Add. Turn it off: it can't run together with Rembrandt660M." ;;
		esac
	done
	(( lilu >= 0 )) || die "Lilu.kext is not in Kernel -> Add."
	if (( rmb >= 0 && rmb != lilu + 1 )); then
		plutil -remove Kernel.Add.$rmb $stage; (( rmb < lilu )) && (( lilu-- )); rmb=-1
		changes+="moved the Rembrandt660M entry directly after Lilu"
	fi
	if (( rmb < 0 )); then
		plutil -insert Kernel.Add.$(( lilu + 1 )) -xml "<dict>
			<key>Arch</key><string>x86_64</string><key>BundlePath</key><string>Rembrandt660M.kext</string>
			<key>Comment</key><string>Radeon 660M driver (Tahoe 25G229)</string><key>Enabled</key><true/>
			<key>ExecutablePath</key><string>Contents/MacOS/Rembrandt660M</string><key>MaxKernel</key><string></string>
			<key>MinKernel</key><string></string><key>PlistPath</key><string>Contents/Info.plist</string></dict>" $stage ||
			die "Could not add the Kernel -> Add entry."
		[[ ${changes[-1]} == moved* ]] || changes+="added Rembrandt660M to Kernel -> Add, directly after Lilu"
	else
		[[ $(plutil -extract Kernel.Add.$rmb.Enabled raw $stage) == true ]] ||
			{ plutil -replace Kernel.Add.$rmb.Enabled -bool YES $stage; changes+="enabled the Rembrandt660M entry"; }
	fi

	# DeviceProperties for the GPU (README step 8.5). Existing keys under that path are kept.
	plutil -extract DeviceProperties.Add raw $stage >/dev/null 2>&1 || plutil -insert DeviceProperties.Add -dictionary $stage
	local dp="DeviceProperties.Add.$devpath"
	plutil -extract "$dp" raw $stage >/dev/null 2>&1 || plutil -insert "$dp" -dictionary $stage
	local k t v cur want
	for k t v in \
		device-id data "$(printf '\xff\x73\x00\x00' | base64)" \
		compatible string pci1002,73ff \
		model string "AMD Radeon 660M" \
		LoadAccelerator bool YES LoadController bool YES LoadHWServices bool YES \
		CFG_USE_AGDC data "$(printf '\x00\x00\x00\x00\x00\x00\x00\x00' | base64)" \
		CFG_NO_BOOT_PWDN data "$(printf '\x01\x00\x00\x00\x00\x00\x00\x00' | base64)" \
		AAPL,iokit-ignore-ndrv data "$(printf '\x01\x00\x00\x00' | base64)"; do
		if cur=$(plutil -extract "$dp.$k" raw $stage 2>/dev/null); then
			# Already there: keep it if it means the same (a string may also be stored as data, with or without NUL).
			want=$v; [[ $t == bool ]] && want=true
			[[ $cur == "$want" || $cur == $(printf '%s' "$v" | base64) ||
				$cur == $(printf '%s\0' "$v" | base64) ]] && continue
			changes+="DeviceProperties: corrected $k (was $cur)"
		else
			changes+="DeviceProperties: set $k"
		fi
		plutil -replace "$dp.$k" -$t "$v" $stage || die "Could not set DeviceProperties $k."
	done
	plutil -extract "$dp.ATY,bin_image" raw $stage >/dev/null 2>&1 &&
		warn "DeviceProperties has ATY,bin_image. It is not needed on 25G229 (left as it is)."

	# boot-args: add -lilubetaall -rmbumd, drop -rem660off (it turns the kext off).
	plutil -extract NVRAM.Add.$GUID raw $stage >/dev/null 2>&1 || die "config.plist has no NVRAM -> Add -> $GUID."
	local args=$(plutil -extract NVRAM.Add.$GUID.boot-args raw $stage 2>/dev/null)
	local -a a=(${=args}) new
	new=(${a:#-rem660off})
	(( ${new[(Ie)-lilubetaall]} )) || new+=-lilubetaall
	(( ${new[(Ie)-rmbumd]} )) || new+=-rmbumd
	if [[ "${(j: :)new}" != "$args" ]]; then
		plutil -replace NVRAM.Add.$GUID.boot-args -string "${(j: :)new}" $stage
		changes+="boot-args: \"$args\" -> \"${(j: :)new}\""
	fi
	# OpenCore only applies boot-args from config.plist if NVRAM -> Delete lists them.
	if ! plutil -extract NVRAM.Delete.$GUID xml1 -o - $stage 2>/dev/null | grep -q '<string>boot-args</string>'; then
		plutil -extract NVRAM.Delete.$GUID raw $stage >/dev/null 2>&1 || plutil -insert NVRAM.Delete.$GUID -array $stage
		plutil -insert NVRAM.Delete.$GUID -string boot-args -append $stage && changes+="NVRAM -> Delete: added boot-args"
	fi

	plutil -lint -s $stage || die "The edited config.plist did not pass plutil. Nothing was written."

	# Write: kext first, then config.plist; check both.
	if [[ -d $T/OC/Kexts/Rembrandt660M.kext ]]; then
		w mv $T/OC/Kexts/Rembrandt660M.kext $(mktemp -d)/ || die "Could not replace the old kext."
	fi
	copy_verified $KEXT $T/OC/Kexts/Rembrandt660M.kext || die "Copying the kext failed its hash check."
	changes+="copied Rembrandt660M.kext ($kexthash)"
	w cp $stage $cfg && [[ $(shasum -a 256 < $stage) == $(shasum -a 256 < $cfg) ]] || die "Writing config.plist failed."
	plutil -lint -s $cfg || die "config.plist on the target doesn't pass plutil after writing."
	sync
	say; say "${B}Changes in $T:${N}"
	for c in $changes; do ok $c; done
}

backup_efi() {  # $1 = EFI folder
	local d=$BACKUPS/$STAMP
	mkdir -p $d || die "Can't create $d"
	copy_verified $1 $d/EFI || die "The backup of $1 failed its hash check."
	ok "Backup: $d/EFI ($(manifest $d/EFI | wc -l | tr -d ' ') files, SHA-256 checked)"
	BACKUP=$d/EFI
}

# --- --efi: patch a given folder ---------------------------------------------------------------------------
if [[ -n $EFI_ARG ]]; then
	say; say "${B}2. Patching $EFI_ARG${N}"
	backup_efi $EFI_ARG
	patch_efi $EFI_ARG
	say; say "Undo: replace $EFI_ARG with $BACKUP"
	finish 0
fi

# --- 2. find and mount the boot EFI ------------------------------------------------------------------------
say; say "${B}2. Finding the EFI partition OpenCore booted from${N}"
bootpath=$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path 2>/dev/null)
uuid=$(print -r -- $bootpath | grep -o -E 'GPT,[0-9A-Fa-f-]{36}' | cut -d, -f2)
dev=""
[[ -n $uuid ]] && dev=$(diskutil info $uuid 2>/dev/null | awk -F': *' '/Device Identifier/ {print $2}')
mountpoint() { diskutil info $1 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}'; }
if [[ -z $dev ]]; then
	# OpenCore only publishes its boot path with ExposeSensitiveData bit 0x1. Look at every FAT partition on
	# internal disks (EFI type or not) for EFI/OC/OpenCore.efi, mounting the EFI ones that aren't mounted.
	cands=()
	for d in $(diskutil list internal physical | grep -o -E 'disk[0-9]+s[0-9]+$'); do
		info=$(diskutil info $d 2>/dev/null)
		[[ $info == *"Type (Bundle):"*msdos* ]] || continue
		m=$(mountpoint $d)
		if [[ -z $m ]]; then
			[[ $info == *"Partition Type:"*EFI* ]] || continue
			say "Mounting $d to look for OpenCore (your password may be asked):"
			sudo diskutil mount $d >/dev/null 2>&1 || continue
			m=$(mountpoint $d)
		fi
		[[ -n $m && -f $m/EFI/OC/OpenCore.efi && -f $m/EFI/OC/config.plist ]] && cands+=$d
	done
	if (( ${#cands} == 1 )); then
		dev=${cands[1]}
	elif (( ${#cands} > 1 )); then
		say "OpenCore is on more than one partition:"
		for (( i = 1; i <= ${#cands}; i++ )); do say "  $i) ${cands[i]} at $(mountpoint ${cands[i]})"; done
		n=$(ask "Which one does the laptop boot from? (number)")
		[[ $n == <-> ]] && (( n >= 1 && n <= ${#cands} )) && dev=${cands[n]}
	fi
fi
[[ -n $dev ]] || die "No OpenCore EFI found on the internal disk. Mount it (README step 8.1) and use
      zsh install.command --efi /Volumes/<name>/EFI"
mp=$(mountpoint $dev)
if [[ -z $mp ]]; then
	say "Mounting $dev (your password may be asked):"
	sudo diskutil mount $dev >/dev/null || die "Could not mount $dev."
	mp=$(mountpoint $dev)
fi
[[ -f $mp/EFI/OC/config.plist && -f $mp/EFI/OC/OpenCore.efi ]] || die "$dev ($mp) has no OpenCore EFI."
ok "OpenCore EFI: $dev mounted at $mp"

# --- 3. what to do -----------------------------------------------------------------------------------------
say; say "${B}3. What do you want to do?${N}"
say "  1) Install on a USB test stick (recommended first: if it fails, unplug the stick and boot as before)"
say "  2) Install on the internal EFI ($dev)"
say "  3) Finish setup after acceleration works (README step 10)"
say "  q) Quit"
case $(ask "Choice:") in
	1) mode=stick ;;
	2) mode=internal ;;
	3) finish_setup ;;
	*) finish 0 ;;
esac

say; say "${B}4. Backing up $mp/EFI${N}"
backup_efi $mp/EFI

if [[ $mode == stick ]]; then
	say; say "${B}5. Choosing the test stick${N}"
	sticks=()
	for v in /Volumes/*(N); do
		[[ $v == $mp ]] && continue
		info=$(diskutil info "$v" 2>/dev/null) || continue
		[[ $info == *"MS-DOS"* ]] || continue
		[[ $info == *"Device Location:"*External* || $info == *"Removable Media:"*Removable* ]] || continue
		sticks+=$v
	done
	if (( ! ${#sticks} )); then
		die "No USB stick formatted as MS-DOS (FAT) is plugged in. In Disk Utility erase one as
      MS-DOS (FAT), scheme GUID Partition Map (README step 8.1), plug it in and run this again."
	fi
	for (( i = 1; i <= ${#sticks}; i++ )); do say "  $i) ${sticks[i]}"; done
	n=$(ask "Which stick? (number)")
	[[ $n == <-> ]] && (( n >= 1 && n <= ${#sticks} )) || die "No stick chosen."
	S=${sticks[n]}
	if [[ -e $S/EFI ]]; then
		yes "$S already has an EFI folder. Rename it to EFI.old-$STAMP and continue?" || finish 0
		mv $S/EFI $S/EFI.old-$STAMP || die "Could not rename $S/EFI."
	fi
	copy_verified $mp/EFI $S/EFI || die "Copying the EFI to $S failed its hash check."
	ok "Copied the EFI to $S"
	patch_efi $S/EFI
	say
	say "${B}Next:${N} restart, open the boot menu (F12 on Lenovo), pick the USB stick, then macOS in OpenCore."
	say "If it hangs: hold power 10 s, unplug the stick, boot normally. Nothing on the internal disk changed."
	say "If it works: run this again and choose 2, then 3. To check anything: zsh doctor.command"
else
	say; say "${B}5. Installing on the internal EFI${N}"
	yes "Write to $mp/EFI now? (the backup above is your way back)" || finish 0
	patch_efi $mp/EFI
	say
	say "${B}Next:${N} restart. If the boot hangs, see README \"If something goes wrong\". To undo, boot from the"
	say "test stick (or add -rem660off to boot-args) and copy $BACKUP back to $mp/EFI."
	say "After it works: run this again and choose 3. To check anything: zsh doctor.command"
fi
finish 0
