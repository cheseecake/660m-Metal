//
//  vtrim.cpp: background trim of the reusable orphaned VRAM cache (IOAcceleratorFamily2), so new GPU
//  allocations find free VRAM instead of failing first and evicting on demand.
//
//  Audit 2026-11-13 (4 GB UMA): IOAcceleratorFamily2 keeps freed video memory (IOAccelVidMemory whose resource
//  went away) in a reusable orphan pool for reuse (hit rate ~96 %). On 25G229 that pool has no size limit
//  (IOGraphicsAccelerator2::start 0x3ba39: init(accel, -1, 0)) and no collector prunes it (the reusable
//  collector 0x3c572 prunes only the system-memory pool at +0xb60, the non-reusable one only the +0x28 lists).
//  It is emptied only on demand: AMD allocateLargeBlocks fails ("AMD ERROR! Failed to allocate size"), the family
//  evicts orphans (IOAccelOrphanedVidMemoryPool::freeWaitToPrepareMemory 0x53c00) and retries. Live: orphans
//  2.2 GB, in use 1.9 GB, vramFreeBytes 92 MB; 8142 failed allocations in 51 min (peak 570/s).
//
//  What this does: a kernel thread estimates free VRAM = VRAM,totalMB - accel+0x360 (every video byte, orphans
//  included: inUseVidMemoryBytes = +0x360 - +0xc18 - +0xc20). Below the reserve it takes the accelerator lock
//  the way Apple's collector does (0x3c572: waiters +0x90, IOLock +0x88, busy +0x158, acceleratorDidLock /
//  acceleratorWillUnlock, unlock_busy) and runs Apple's non-waiting eviction step (0x53ccb..0x53d3c) on the
//  oldest orphans: testAllEvent() (GPU done with it), then pruneOrphanedMappings(). It never waits for the GPU,
//  never touches memory a client still owns, frees at most 128 MB per lock hold and stops when the reserve
//  plus 256 MB is free or 64 MB of cache is left. Sleep (+0xc78 & 0x10) and no-prune (& 0x8) states are skipped.
//
//  Layout, 25G229 IOAcceleratorFamily2 LC_UUID 6C4A16B1-66DC-3A8B-9F0B-D3E027B16EB1 (RVA = KDK address):
//    accel +0x88 IOLock*, +0x90 lock waiters, +0x158 busy count, +0x360 video bytes, +0xbc8 vid orphan pool,
//          +0xc78 flags; vtable +0x850 acceleratorDidLock(const char *, int), +0x858 acceleratorWillUnlock.
//    pool  vtable init 0x5320c, free 0x532b6, getMemory 0x53704, freeWaitToPrepareMap 0x53ab2,
//          freeWaitToPrepareMemory 0x53c00; +0x08 accel, +0x18 reusable list head (oldest first; element +0
//          IOAccelMemory *, +8 next), +0x40 count, +0x50 bytes (= orphanedReusableVidMemoryBytes, accel+0xc18).
//    IOAccelMemory vtable +0x120 getLength(); testAllEvent 0x1eac; pruneOrphanedMappings 0x1f0e;
//    IOGraphicsAccelerator2::unlock_busy 0x41db4.
//  Checked in memory before use: LC_UUID, the code that encodes every offset above (relocation-free spans of
//  the KDK image, from otool -r), the pool's five vtable entries and its accel back pointer. Any mismatch =
//  off for the boot.
//
//  -rmbnovtrim: off. rmbvtrim=<MB>: reserve (default 512, 0 = off). /Users/Shared/rmb-vtrim.ctl, re-read every
//  2 s: "off", "on", or a reserve in MB (64..2048).
//

#include "rmb.hpp"
#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <libkern/OSAtomic.h>
#include <libkern/c++/OSNumber.h>
#include <kern/thread.h>
#include <mach-o/loader.h>
#include <mach/kmod.h>
#include <string.h>

extern "C" boolean_t PE_parse_boot_argn(const char *arg_string, void *arg_ptr, int max_arg);

namespace {

constexpr const char *Bundle = "com.apple.iokit.IOAcceleratorFamily2";
const uint8_t Uuid[16] {0x6c, 0x4a, 0x16, 0xb1, 0x66, 0xdc, 0x3a, 0x8b, 0x9f, 0x0b, 0xd3, 0xe0, 0x27, 0xb1, 0x6e, 0xb1};
constexpr const char *CtlPath = "/Users/Shared/rmb-vtrim.ctl";

constexpr uint32_t RvaTestAllEvent = 0x1eac, RvaPruneMappings = 0x1f0e, RvaUnlockBusy = 0x41db4;
constexpr uint32_t RvaPoolVt[5] {0x5320c, 0x532b6, 0x53704, 0x53ab2, 0x53c00};

constexpr size_t AccLock = 0x88, AccLockWaiters = 0x90, AccBusy = 0x158, AccVidBytes = 0x360, AccVidPool = 0xbc8,
                 AccFlags = 0xc78, VtDidLock = 0x850, VtWillUnlock = 0x858;
constexpr uint32_t FlagNoPrune = 0x8, FlagSleeping = 0x10;
constexpr size_t PoolAccel = 0x08, PoolHead = 0x18, PoolCount = 0x40, PoolBytes = 0x50, MemVtGetLength = 0x120;

constexpr uint64_t MB = 1024 * 1024;
constexpr uint64_t PassMax = 128 * MB, Hysteresis = 256 * MB, CacheFloor = 64 * MB;
constexpr uint32_t VisitMax = 512, TickMs = 250, BurstMs = 10, IdleBackoffMs = 5000;

struct Site {
	uint32_t rva, len;
	const char *bytes;
};

// Relocation-free spans of the 25G229 KDK image; external call targets (rel32) are skipped.
const Site Sites[] {
	{0x3c572, 21, "\x55\x48\x89\xe5\x41\x56\x53\x48\x89\xfb\x4c\x8d\xb7\x90\x00\x00\x00\x4c\x89\xf7\xe8"},  // collector
	{0x3c58b, 8, "\x48\x8b\xbb\x88\x00\x00\x00\xe8"},  // collector
	{0x3c597, 4, "\x4c\x89\xf7\xe8"},  // collector
	{0x3c59f, 8, "\x48\x8d\xbb\x58\x01\x00\x00\xe8"},  // collector
	{0x3c5ab, 149, "\x48\x8b\x03\x48\x8d\x35\x33\xbc\x01\x00\x48\x89\xdf\x31\xd2\xff\x90\x50\x08\x00\x00\xf6\x83\x78\x0c\x00\x00\x02\x74\x4e\x48\x89\xdf\xe8\x21\x41\x00\x00\x48\x8d\xbb\x60\x0b\x00\x00\xe8\xdf\x6d\x01\x00\x83\xbb\xa0\x0b\x00\x00\x00\x74\x31\x83\xbb\xec\x00\x00\x00\x00\x75\x28\xf6\x83\x78\x0c\x00\x00\x10\x75\x1f\xc7\x83\xec\x00\x00\x00\x01\x00\x00\x00\x48\x8b\xbb\x30\x01\x00\x00\x48\x8b\x07\xbe\x60\xea\x00\x00\xff\x90\xd0\x01\x00\x00\x48\x8b\x03\x48\x8d\x35\xc7\xbb\x01\x00\x48\x89\xdf\x31\xd2\xff\x90\x58\x08\x00\x00\x48\x89\xdf\xe8\x80\x57\x00\x00\x48\x8b\xbb\x88\x00\x00\x00\x5b\x41\x5e\x5d\xe9"},  // collector
	{0x533bc, 72, "\x48\x8b\x47\x18\x48\x85\xc0\x74\x3e\x55\x48\x89\xe5\x41\x56\x53\x48\x89\xfb\x48\x8b\x38\x4c\x8b\x70\x08\x48\x8b\x4b\x50\x48\x3b\x4b\x48\x77\x12\x8b\x4b\x10\x03\x48\x2c\x48\x8b\x43\x08\x3b\x88\xbc\x00\x00\x00\x73\x0d\xe8\x17\xeb\xfa\xff\x4c\x89\xf0\x4d\x85\xf6\x75\xd0\x5b\x41\x5e\x5d\xc3"},  // pruneReusable
	{0x53ccb, 115, "\x49\x8b\x5c\x24\x18\x45\x31\xe4\x48\x85\xdb\x74\x64\x4c\x8b\x2b\x48\x8b\x5b\x08\x80\x7d\xd4\x00\x74\x16\x4c\x89\xef\xe8\x13\x22\x00\x00\x84\xc0\x75\x16\x4c\x89\xef\xe8\x23\xe9\xfa\xff\xeb\x0c\x4c\x89\xef\xe8\xa9\xe1\xfa\xff\x84\xc0\x74\x2d\x49\x8b\x45\x00\x4c\x89\xef\xff\x90\x20\x01\x00\x00\x41\x01\xc4\x4c\x89\xef\xe8\xef\xe1\xfa\xff\x4d\x39\xe7\x77\x10\x49\x8b\x06\x4c\x89\xf7\xff\x90\x48\x01\x00\x00\x84\xc0\x75\x92\x48\x85\xdb\x75\x9f\x45\x31\xe4\x44\x89"},  // vidEvict
	{0x2f584, 46, "\x49\x8b\x46\x10\x8b\xb0\x08\x0c\x00\x00\x48\x8d\x15\x61\xdc\x02\x00\x48\x89\xdf\xe8\xf5\xf7\xff\xff\x49\x8b\x46\x10\x48\x8b\xb0\x18\x0c\x00\x00\x48\x8d\x15\x66\xdc\x02\x00\x48\x89\xdf"},  // statsOrphan
	{0x2f61a, 28, "\x49\x8b\x46\x10\x48\x8b\xb0\x60\x03\x00\x00\x48\x8b\x88\x18\x0c\x00\x00\x48\x03\x88\x20\x0c\x00\x00\x48\x29\xce"},  // statsInUse
	{0x55f42, 23, "\xbf\xc8\x0b\x00\x00\x48\x03\x7b\x28\x48\x89\xde\x48\x83\xc4\x08\x5b\x5d\xe9\x6b\xd6\xff\xff"},  // orphanIt
	{0x01eac, 16, "\x55\x48\x89\xe5\x41\x56\x53\x48\x89\xfb\x66\x83\x7f\x5a\x00\x7e"},  // testAllEvent
	{0x01f0e, 96, "\x55\x48\x89\xe5\x41\x57\x41\x56\x53\x50\x48\x8b\x47\x28\xf6\x80\x78\x0c\x00\x00\x08\x75\x3e\x48\x89\xfb\x4c\x0f\xbf\x7f\x5a\x4d\x85\xff\x7e\x31\x49\xff\xc7\x48\x8b\x43\x50\x4e\x8b\x74\xf8\xf0\x41\xf6\x46\x10\x08\x74\x15\x4c\x89\xf7\xe8\x15\x05\x05\x00\x84\xc0\x74\x09\x49\x8b\x06\x4c\x89\xf7\xff\x50\x28\x49\xff\xcf\x49\x83\xff\x01\x77\xd2\x48\x83\xc4\x08\x5b\x41\x5e\x41\x5f\x5d\xc3"},  // pruneMappings
	{0x41db4, 17, "\x55\x48\x89\xe5\x53\x50\x48\x89\xfb\x48\x81\xc7\x58\x01\x00\x00\xe8"},  // unlockBusy
	{0x41dc9, 69, "\x83\xf8\x01\x75\x39\xf6\x83\x78\x0c\x00\x00\x04\x75\x30\x48\x8b\x93\x60\x01\x00\x00\x48\x85\xd2\x74\x24\x48\x8b\x03\x48\x8b\x8b\x68\x01\x00\x00\x48\x8b\x80\x38\x07\x00\x00\x48\x89\xdf\xbe\x01\x80\xff\xe3\x45\x31\xc0\x48\x83\xc4\x08\x5b\x5d\xff\xe0\x48\x83\xc4\x08\x5b\x5d\xc3"},  // unlockBusy
	{0x3ba19, 60, "\x49\x8d\xbe\x60\x0b\x00\x00\x48\x8b\x55\xb8\x48\xc1\xea\x02\x49\x8b\x86\x60\x0b\x00\x00\x4c\x89\xf6\xb9\xc0\x12\x00\x00\xff\x10\x49\x8d\xbe\xc8\x0b\x00\x00\x49\x8b\x86\xc8\x0b\x00\x00\x4c\x89\xf6\x48\xc7\xc2\xff\xff\xff\xff\x31\xc9\xff\x10"},  // startPoolInit
};

using BoolFn = bool (*)(void *);
using VoidFn = void (*)(void *);
using LockFn = void (*)(void *, const char *, int);
using LenFn = uint64_t (*)(const void *);

BoolFn gTestAllEvent;
VoidFn gPruneMappings, gUnlockBusy;
IOService *gAcc;
uint8_t *gA;              // accelerator object bytes
uint64_t gTotal;          // VRAM bytes (VRAM,totalMB)
uint32_t gReserveMb = 512;
bool gEnabled = true;

template <typename T> T rd(const uint8_t *p, size_t off) { return *reinterpret_cast<const volatile T *>(p + off); }

uint64_t nowUs() {
	uint64_t ns;
	absolutetime_to_nanoseconds(mach_absolute_time(), &ns);
	return ns / 1000;
}

// IOAcceleratorFamily2 __TEXT base if its in-memory LC_UUID and every guarded span match 25G229, else 0.
mach_vm_address_t verifiedFamily() {
	for (auto k = kmodList(); k; k = k->next) {
		if (strncmp(k->name, Bundle, KMOD_MAX_NAME))
			continue;
		auto base = static_cast<mach_vm_address_t>(k->address);
		auto hdr = reinterpret_cast<const mach_header_64 *>(base);
		if (!base || hdr->magic != MH_MAGIC_64 || hdr->ncmds > 64 || hdr->sizeofcmds > 0x4000) {
			LOG("vtrim: %s: no 64-bit Mach-O header at the kmod address: off", Bundle);
			return 0;
		}
		bool uuidOk = false;
		uint64_t textSize = 0;
		auto p = reinterpret_cast<const uint8_t *>(base + sizeof(mach_header_64));
		auto end = p + hdr->sizeofcmds;
		for (uint32_t i = 0; i < hdr->ncmds && p + sizeof(load_command) <= end; i++) {
			auto lc = reinterpret_cast<const load_command *>(p);
			if (lc->cmdsize < sizeof(load_command) || p + lc->cmdsize > end)
				break;
			if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(uuid_command))
				uuidOk = !memcmp(reinterpret_cast<const uuid_command *>(p)->uuid, Uuid, sizeof(Uuid));
			else if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(segment_command_64) &&
			         !strncmp(reinterpret_cast<const segment_command_64 *>(p)->segname, SEG_TEXT, 16))
				textSize = reinterpret_cast<const segment_command_64 *>(p)->vmsize;
			p += lc->cmdsize;
		}
		if (!uuidOk || !textSize) {
			LOG("vtrim: %s: LC_UUID %s, __TEXT size %llx: not the 25G229 image: off", Bundle,
			    uuidOk ? "match" : "MISMATCH", textSize);
			return 0;
		}
		size_t bad = 0;
		for (auto &s : Sites)
			if (s.rva + s.len > textSize || memcmp(reinterpret_cast<const void *>(base + s.rva), s.bytes, s.len)) {
				LOG("vtrim: %s: code at +%x (%u bytes) differs from 25G229", Bundle, s.rva, s.len);
				bad++;
			}
		if (bad) {
			LOG("vtrim: %zu/%zu guarded spans differ: off", bad, arrsize(Sites));
			return 0;
		}
		return base;
	}
	LOG("vtrim: %s not in the kmod list: off", Bundle);
	return 0;
}

// The vid orphan pool at accel+0xbc8 must be the 25G229 IOAccelOrphanedVidMemoryPool pointing back at accel.
bool poolOk(mach_vm_address_t base) {
	auto vt = rd<const uint64_t *>(gA, AccVidPool);
	if (!vt || rd<uint8_t *>(gA + AccVidPool, PoolAccel) != gA) {
		LOG("vtrim: accel+0xbc8 is not an orphan pool of this accelerator: off");
		return false;
	}
	for (size_t i = 0; i < arrsize(RvaPoolVt); i++)
		if (vt[i] != base + RvaPoolVt[i]) {
			LOG("vtrim: pool vtable slot %zu = %llx, expected IOAcceleratorFamily2+%x: off", i,
			    vt[i] - base, RvaPoolVt[i]);
			return false;
		}
	return rd<IOLock *>(gA, AccLock) != nullptr;
}

uint64_t vramTotal(IOService *acc) {
	for (IORegistryEntry *e = acc; e; e = e->getParentEntry(gIOServicePlane)) {
		static const char *const keys[] {"VRAM,totalMB", "ATY,memsize"};
		for (auto key : keys) {
			auto o = e->copyProperty(key);
			auto n = OSDynamicCast(OSNumber, o);
			uint64_t v = n ? n->unsigned64BitValue() : 0;
			OSSafeReleaseNULL(o);
			if (v && key[0] == 'V')
				return v * MB;
			if (v)
				return v;
		}
	}
	return 0;
}

struct Pass {
	uint32_t pruned, busy, visited;
	uint64_t freed, holdUs;
	bool skipped;
};

// Apple's non-waiting eviction step on the oldest orphans, under the collector's lock sequence.
// Progress is what the pool really lost (pruneOrphanedMappings frees the memory only with its last mapping).
void trimPass(uint64_t want, Pass &p) {
	p = {};
	auto lock = rd<IOLock *>(gA, AccLock);
	auto waiters = reinterpret_cast<volatile SInt32 *>(gA + AccLockWaiters);
	auto busy = reinterpret_cast<volatile SInt32 *>(gA + AccBusy);
	auto vtbl = rd<const uint8_t *>(gA, 0);
	OSIncrementAtomic(waiters);
	IOLockLock(lock);
	OSDecrementAtomic(waiters);
	OSIncrementAtomic(busy);
	reinterpret_cast<LockFn>(rd<uintptr_t>(vtbl, VtDidLock))(gA, "", 0);
	auto t0 = nowUs();
	if (rd<uint32_t>(gA, AccFlags) & (FlagNoPrune | FlagSleeping)) {
		p.skipped = true;
	} else {
		uint8_t *pool = gA + AccVidPool;
		uint64_t before = rd<uint64_t>(pool, PoolBytes);
		for (auto e = rd<uint8_t *>(pool, PoolHead); e && p.visited < VisitMax; p.visited++) {
			auto mem = rd<uint8_t *>(e, 0);
			auto next = rd<uint8_t *>(e, 8);
			if (mem && gTestAllEvent(mem)) {
				gPruneMappings(mem);
				p.pruned++;
			} else {
				p.busy++;
			}
			uint64_t now = rd<uint64_t>(pool, PoolBytes);
			p.freed = before > now ? before - now : 0;
			if (p.freed >= want)
				break;
			e = next;
		}
	}
	p.holdUs = nowUs() - t0;
	reinterpret_cast<LockFn>(rd<uintptr_t>(vtbl, VtWillUnlock))(gA, "", 0);
	gUnlockBusy(gA);
	IOLockUnlock(lock);
}

void readCtl(int64_t &lastMtime) {
	int64_t t = 0;
	if (!rmbFileRead(CtlPath, nullptr, 0, &t) || t == lastMtime)
		return;
	lastMtime = t;
	char buf[32] {};
	if (!rmbFileRead(CtlPath, buf, sizeof(buf), nullptr))
		return;
	if (!strncmp(buf, "off", 3)) {
		gEnabled = false;
	} else if (!strncmp(buf, "on", 2)) {
		gEnabled = true;
	} else if (buf[0] >= '0' && buf[0] <= '9') {
		uint32_t v = 0;
		for (const char *c = buf; *c >= '0' && *c <= '9' && v < 100000; c++)
			v = v * 10 + static_cast<uint32_t>(*c - '0');
		gReserveMb = v < 64 ? 64 : v > 2048 ? 2048 : v;
		gEnabled = true;
	}
	LOG("vtrim: %s: %s, reserve %u MB", CtlPath, gEnabled ? "on" : "off", gReserveMb);
}

void vtrimThread(void *, wait_result_t) {
	auto match = IOService::serviceMatching("IOGraphicsAccelerator2");
	gAcc = match ? IOService::waitForMatchingService(match, 600ULL * NSEC_PER_SEC) : nullptr;
	OSSafeReleaseNULL(match);
	if (!gAcc || !gAcc->metaCast("IOGraphicsAccelerator2")) {
		LOG("vtrim: no IOGraphicsAccelerator2 within 600 s: off");
		OSSafeReleaseNULL(gAcc);
		return;
	}
	gA = reinterpret_cast<uint8_t *>(gAcc);
	auto base = verifiedFamily();
	if (!base || !poolOk(base)) {
		OSSafeReleaseNULL(gAcc);
		return;
	}
	gTestAllEvent = reinterpret_cast<BoolFn>(base + RvaTestAllEvent);
	gPruneMappings = reinterpret_cast<VoidFn>(base + RvaPruneMappings);
	gUnlockBusy = reinterpret_cast<VoidFn>(base + RvaUnlockBusy);
	LOG("vtrim: %s %s verified (LC_UUID 6C4A16B1 + %zu code spans + pool vtable), waiting 30 s",
	    gAcc->getMetaClass()->getClassName(), Bundle, arrsize(Sites));

	// Let the login session settle before the first trim. The accelerator matches before the GPU node gets
	// VRAM,totalMB (boot 11-15: matched at 12.25 s, no total yet), so read the total only after this and
	// keep polling for up to 5 more minutes.
	IOSleep(30000);
	uint8_t *pool = gA + AccVidPool;
	uint64_t vid = 0;
	for (uint32_t waited = 0;; waited += 2) {
		if (gAcc->isInactive()) {
			LOG("vtrim: accelerator terminated before start: off");
			OSSafeReleaseNULL(gAcc);
			return;
		}
		gTotal = vramTotal(gAcc);
		vid = rd<uint64_t>(gA, AccVidBytes);
		if (gTotal && vid <= gTotal)
			break;
		if (waited >= 300) {
			LOG("vtrim: VRAM size %llu MB, video allocated %llu MB after 330 s: no usable total: off", gTotal / MB,
			    vid / MB);
			OSSafeReleaseNULL(gAcc);
			return;
		}
		IOSleep(2000);
	}
	LOG("vtrim: on (%s %s, LC_UUID 6C4A16B1 + %zu code spans + pool vtable verified), reserve %u MB: VRAM %llu MB, "
	    "video allocated %llu MB, orphan cache %llu MB (%u), est. free %llu MB",
	    gAcc->getMetaClass()->getClassName(), Bundle, arrsize(Sites), gReserveMb, gTotal / MB, vid / MB,
	    rd<uint64_t>(pool, PoolBytes) / MB, rd<uint32_t>(pool, PoolCount), (gTotal - vid) / MB);
	int64_t ctlMtime = -1;
	uint64_t lastCtl = 0, winT0 = nowUs(), backoffUntil = 0;
	struct {
		uint32_t passes, pruned, busy, skipped;
		uint64_t freed, holdMaxUs, minFree;
	} w {};
	w.minFree = ~0ULL;
	bool first = true;
	for (;;) {
		uint64_t now = nowUs();
		if (now - lastCtl >= 2000000) {
			lastCtl = now;
			readCtl(ctlMtime);
		}
		if (gAcc->isInactive()) {
			LOG("vtrim: accelerator terminated: stop");
			break;
		}
		uint32_t sleepMs = TickMs;
		uint64_t vidNow = rd<uint64_t>(gA, AccVidBytes);
		uint64_t orphan = rd<uint64_t>(pool, PoolBytes);
		uint64_t freeB = vidNow < gTotal ? gTotal - vidNow : 0;
		uint64_t reserve = gReserveMb * MB;
		if (freeB < w.minFree)
			w.minFree = freeB;
		if (gEnabled && now >= backoffUntil && freeB < reserve && orphan > CacheFloor) {
			uint64_t want = reserve + Hysteresis - freeB;
			if (want > orphan - CacheFloor)
				want = orphan - CacheFloor;
			if (want > PassMax)
				want = PassMax;
			Pass p;
			trimPass(want, p);
			w.passes++;
			w.pruned += p.pruned;
			w.busy += p.busy;
			w.skipped += p.skipped;
			w.freed += p.freed;
			if (p.holdUs > w.holdMaxUs)
				w.holdMaxUs = p.holdUs;
			if (first || p.holdUs >= 20000) {
				first = false;
				LOG("vtrim: pass: est. free %llu MB < reserve %u MB, want %llu MB: freed %llu MB, pruned %u, busy %u, "
				    "visited %u, %s, lock held %llu us", freeB / MB, gReserveMb, want / MB, p.freed / MB, p.pruned,
				    p.busy, p.visited, p.skipped ? "SKIPPED (sleep/no-prune flag)" : "ran", p.holdUs);
			}
			if (p.skipped || !p.freed)
				backoffUntil = nowUs() + IdleBackoffMs * 1000ULL;
			else if (p.freed >= want && freeB + p.freed < reserve + Hysteresis)
				sleepMs = BurstMs;
		}
		if (now - winT0 >= 60000000) {
			if (w.passes)
				LOG("vtrim: last 60 s: %u passes, freed %llu MB (pruned %u, busy %u, skipped %u), max lock hold %llu us, "
				    "min est. free %llu MB; now free %llu MB, orphan cache %llu MB (%u)", w.passes, w.freed / MB,
				    w.pruned, w.busy, w.skipped, w.holdMaxUs, w.minFree / MB,
				    (gTotal - rd<uint64_t>(gA, AccVidBytes)) / MB, rd<uint64_t>(pool, PoolBytes) / MB,
				    rd<uint32_t>(pool, PoolCount));
			w = {};
			w.minFree = ~0ULL;
			winT0 = now;
		}
		IOSleep(sleepMs);
	}
	OSSafeReleaseNULL(gAcc);
}

}  // namespace

void vramTrimStart() {
	if (checkKernelArgument("-rmbnovtrim")) {
		LOG("vtrim: disabled (-rmbnovtrim)");
		return;
	}
	uint32_t mb = 0;
	if (PE_parse_boot_argn("rmbvtrim", &mb, sizeof(mb))) {
		if (!mb) {
			LOG("vtrim: disabled (rmbvtrim=0)");
			return;
		}
		gReserveMb = mb < 64 ? 64 : mb > 2048 ? 2048 : mb;
	}
	thread_t t;
	if (kernel_thread_start(vtrimThread, nullptr, &t) == KERN_SUCCESS)
		thread_deallocate(t);
	else
		LOG("vtrim: thread start FAILED");
}
