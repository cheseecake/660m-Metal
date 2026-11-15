#!/bin/zsh
# 660m-Metal doctor: checks the install and packs everything needed for a GitHub issue into one zip.
#
# Double-click it in Finder, or run it in Terminal:   zsh doctor.command
#
# No sudo, changes nothing. The zip lands on your Desktop. Before it is written, Wi-Fi network names and
# MAC addresses are masked, and your user name and computer name are replaced. Serial numbers, the VBIOS
# and config.plist's PlatformInfo are never included. Look inside the zip before you attach it if you like.

emulate -L zsh
setopt pipe_fail no_nomatch

NEED_BUILD=25G229
KEXT_ID=org.rembrandt660m.restore
L=/private/var/log/rmb-msgbuf.log
P=/private/var/log/rmb-msgbuf.prev.log
STAMP=$(date +%Y%m%d-%H%M%S)
ZIP=$HOME/Desktop/660m-doctor-$STAMP.zip
OUT=$(mktemp -d)/660m-doctor-$STAMP
mkdir -p $OUT || { print "Can't create $OUT"; exit 1; }

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B= G= Y= R= N=; fi
SUM=$OUT/summary.txt
line() { print -r -- "$1  $2" >> $SUM; print -r -- "${3}$1${N}  $2"; }
pass() { line "  OK" "$*" $G; }
warn() { line "WARN" "$*" $Y; }
fail() { line "FAIL" "$*" $R; }
info() { line "    " "$*" ""; }

host=$(scutil --get ComputerName 2>/dev/null); lhost=$(scutil --get LocalHostName 2>/dev/null)
# Masks what could identify the owner: MAC addresses, Wi-Fi names, user and computer names, serials.
redact() {
	sed -E -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/xx:xx:xx:xx:xx:xx/g' \
		-e 's/([Ss][Ss][Ii][Dd][^=:<]{0,12}[=:<]).*/\1 <masked>/' \
		-e 's/[[:<:]][0-9]{1,3}(\.[0-9]{1,3}){3}[[:>:]]/x.x.x.x/g' \
		-e "s/[[:<:]]${USER:-__nouser__}[[:>:]]/<user>/g" \
		-e "s/[[:<:]]${host:-__nohost__}[[:>:]]/<computer>/g" -e "s/[[:<:]]${lhost:-__nohost__}[[:>:]]/<computer>/g" \
		-e '/[Ss]erial/d'
}
grab() { local f=$1; shift; { "$@" 2>&1 } | redact > $OUT/$f; }

print "${B}660m-Metal doctor${N}"
print "660m-Metal doctor $STAMP" > $SUM
print >> $SUM

# --- system --------------------------------------------------------------------------------------------------
build=$(sw_vers -buildVersion)
[[ $build == $NEED_BUILD ]] && pass "macOS $(sw_vers -productVersion) build $build" ||
	fail "macOS build $build: the kext only works on $NEED_BUILD (README step 5; boot with -rem660off to get in)"
bootargs=$(nvram boot-args 2>/dev/null | cut -f2-)
info "boot-args: ${bootargs:-<none>}"
[[ " $bootargs " == *" -rmbumd "* ]] || warn "-rmbumd is not in boot-args: text and icons will be scrambled (README step 8.6)"
[[ " $bootargs " == *" -lilubetaall "* ]] || warn "-lilubetaall is not in boot-args: Lilu may refuse to run on Tahoe"
[[ " $bootargs " == *" -rem660off "* ]] && warn "-rem660off is in boot-args: the kext is switched off on purpose"
grab system.txt zsh -c "sw_vers; uname -v; sysctl -n hw.model machdep.cpu.brand_string hw.memsize; uptime;
	print; print boot-args: \$(nvram boot-args 2>/dev/null | cut -f2-); csrutil status; print;
	kmutil showloaded --list-only 2>/dev/null | grep -v com.apple"

# --- GPU ----------------------------------------------------------------------------------------------------
gpu=$(ioreg -r -c IOPCIDevice -l -w0 -d1 | awk '
	function emit() { if (!done && v == "<02100000>" && (d == "<81160000>" || d == "<ff730000>")) { print n "|" a "|" sv "|" ss "|" rv "|" d; done = 1 } }
	/^\+-o/ { emit(); n = $2; v = d = a = sv = ss = rv = "" }
	/"vendor-id" =/ { v = $NF } /"device-id" =/ { d = $NF } /"acpi-path" =/ { a = $NF }
	/"subsystem-vendor-id" =/ { sv = $NF } /"subsystem-id" =/ { ss = $NF } /"revision-id" =/ { rv = $NF }
	END { emit() }')
hexle() { local h=${1//[<>\"]/}; print -r -- ${h[3,4]}${h[1,2]}; }
if [[ -n $gpu ]]; then
	IFS='|' read -r node acpi sv ss rv did <<< "$gpu"
	info "GPU: ioreg $node, subsystem $(hexle $sv):$(hexle $ss), revision ${${rv//[<>]/}[1,2]}, device-id $did, ${acpi//\"/}"
	[[ $did == "<ff730000>" ]] && pass "DeviceProperties device-id FF730000 is applied" ||
		fail "device-id is still 1681: the DeviceProperties from README step 8.5 are not applied (wrong PCI path?)"
	# The GPU node without the VBIOS image.
	ioreg -r -n ${node%%@*} -l -w0 -d1 | grep -v -E 'ATY,bin_image|ATY,bin' | redact > $OUT/gpu-ioreg.txt
else
	fail "No Radeon 660M (PCI 1002:1681) found"
fi

kexts=$(kmutil showloaded --list-only 2>/dev/null)
if [[ $kexts == *$KEXT_ID* ]]; then pass "Rembrandt660M is loaded"
else fail "Rembrandt660M is not loaded (Kernel -> Add order: directly after Lilu; check -rem660off)"; fi
[[ $kexts == *as.vit9696.Lilu* ]] && pass "Lilu is loaded" || fail "Lilu is not loaded"
for k in WhateverGreen NootedRed; do
	[[ ${kexts:l} == *${k:l}* ]] && fail "$k is loaded: turn it off, it conflicts with Rembrandt660M"
done

disp=$(system_profiler SPDisplaysDataType 2>/dev/null)
print -r -- $disp | redact > $OUT/displays.txt
metal=$(print -r -- $disp | grep -m1 'Metal Support' | sed 's/.*: //')
vram=$(print -r -- $disp | grep -m1 'VRAM' | sed 's/.*: //')
[[ $metal == Metal* ]] && pass "Metal: $metal, VRAM ${vram:-?}" || fail "No Metal support reported (acceleration is off)"
print -r -- $disp | grep -E 'UI Looks like' | while read -r l; do info "Display: ${l#*: }"; done

# --- kext log -----------------------------------------------------------------------------------------------
if [[ -r $L ]]; then
	vb=$(grep -a '\[vbios\]' $L | tail -1)
	case $vb in
		*rejected*) fail "VBIOS rejected: ${vb##*\] } (README \"If something goes wrong\": build your own kext)" ;;
		*" set from "*|*bin_image*) pass "VBIOS: ${vb##*\[vbios\] }" ;;
		"") warn "No [vbios] line in the kext log" ;;
		*) info "VBIOS: ${vb##*\[vbios\] }" ;;
	esac
	r=$(grep -a -c 'Trying to restart GPU' $L); t=$(grep -a -c 'transaction stamp index' $L)
	(( r )) && warn "$r GPU restart(s) this boot" || pass "No GPU restarts this boot"
	(( t )) && warn "$t display pipe timeout(s) this boot"
	redact < $L > $OUT/rmb-msgbuf.log
else
	warn "No kext log at $L (the kext didn't run this boot)"
fi
if [[ -r $P ]]; then
	if tail -c 2000 $P | grep -a -q 'disklog: shutdown'; then pass "The previous boot shut down cleanly"
	else warn "The previous boot did not shut down cleanly (freeze, forced off or panic): rmb-msgbuf.prev.log is included"; fi
	r=$(grep -a -c 'Trying to restart GPU' $P); (( r )) && warn "$r GPU restart(s) at the end of the previous boot"
	redact < $P > $OUT/rmb-msgbuf.prev.log
fi

# --- crash reports (last 7 days) ------------------------------------------------------------------------------
mkdir -p $OUT/reports
n=0
for f in /Library/Logs/DiagnosticReports/{*.panic,Kernel*.ips,*.gpuRestart}(N.m-7) ~/Library/Logs/DiagnosticReports/WindowServer*(N.m-7); do
	redact < $f > $OUT/reports/${f:t} 2>/dev/null && (( n++ ))
done
(( n )) && warn "$n kernel panic / GPU restart / WindowServer report(s) in the last 7 days (included)" ||
	pass "No kernel panic or GPU restart reports in the last 7 days"

# --- power and updates ------------------------------------------------------------------------------------------
sl=$(pmset -g 2>/dev/null | awk '$1 == "sleep" {print $2}')
[[ $sl == 0 ]] && pass "Sleep is off" || warn "Sleep is $sl min: sleep doesn't work with this kext, run install.command option 3 (or: sudo pmset -a sleep 0)"
au=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>/dev/null)
[[ $au == 1 ]] && warn "Automatic macOS updates are on: an update breaks the kext (install.command option 3)"
avc=$(defaults read com.apple.AppleGVA gvaForceAMDAVCDecode 2>/dev/null)
[[ $avc == 1 ]] && pass "Hardware video decode is on" || info "Hardware video decode is off (install.command option 3)"

# --- OpenCore config (only if an EFI is mounted; PlatformInfo and data blobs left out) --------------------------
cfg=""
for v in /Volumes/*(N); do [[ -f $v/EFI/OC/config.plist && -f $v/EFI/OC/OpenCore.efi ]] && { cfg=$v/EFI/OC/config.plist; break; }; done
if [[ -n $cfg ]]; then
	{
		print "config.plist from ${cfg:h:h:h:t} (PlatformInfo left out, data longer than 64 bytes shortened)"
		for k in Kernel.Add Kernel.Quirks Kernel.Patch Booter.Quirks DeviceProperties.Add NVRAM.Add.7C436110-AB2A-4BBB-A880-FE41995C9F82 NVRAM.Delete Misc.Security; do
			print "\n=== $k"
			plutil -extract $k xml1 -o - $cfg 2>/dev/null | awk '
				/<data>/ { d = 1; buf = ""; next } d && /<\/data>/ { d = 0; print (length(buf) > 88 ? "\t<data>[" int(length(buf) * 3 / 4) " bytes]</data>" : "\t<data>" buf "</data>"); next }
				d { gsub(/[ \t]/, ""); buf = buf $0; next } { print }' | grep -v -E '^<\?xml|^<!DOCTYPE|^<plist|^</plist'
		done
	} | redact > $OUT/opencore-config.txt
	kx=$(plutil -extract Kernel.Add xml1 -o - $cfg | grep -A0 '<string>.*\.kext</string>' | sed -E 's/.*<string>(.*)<\/string>.*/\1/' | tr '\n' ' ')
	[[ $kx == Lilu.kext\ Rembrandt660M.kext* ]] && pass "config.plist: Rembrandt660M directly after Lilu" ||
		info "config.plist kexts in order: $kx"
	kh=$(shasum -a 256 ${cfg:h}/Kexts/Rembrandt660M.kext/Contents/MacOS/Rembrandt660M 2>/dev/null | cut -c1-8)
	info "Kext on the EFI: ${kh:-missing}"
else
	info "No OpenCore EFI is mounted, so config.plist is not included (install.command mounts it)"
fi

# --- pack -----------------------------------------------------------------------------------------------------
(cd ${OUT:h} && zip -q -r $ZIP ${OUT:t}) || { print "zip failed; the files are in $OUT"; exit 1; }
print
print "${B}Saved:${N} $ZIP"
print "Attach it to a GitHub issue with what you did and what you saw. Never attach VFCT.bin."
[[ -t 0 ]] && { print; read -r "?Press Return to close. "; }
exit 0
