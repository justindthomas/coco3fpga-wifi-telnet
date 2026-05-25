# Build & install the NitrOS-9 WiFi telnet bridge.
#
# Required environment / arguments:
#   NITROS9_SRC : path to a NitrOS-9 v3.3.0 source tree (for the
#                 `use defsfile` includes that scwpt/wtbridge/wt/etc.
#                 reference; we pick up the kernel/SCF/etc. defs from
#                 here, not the modules).
#   DISK        : path to the .dsk image to install into.  Must already
#                 contain a NitrOS-9 root filesystem with an OS9Boot
#                 we can pull as our pristine baseline.
#   PRISTINE    : (optional) path to a stock NitrOS-9 OS9Boot file.
#                 If unset, we auto-extract one from $(DISK) the first
#                 time you build the boot target and cache it.
#   LWASM       : lwasm binary (default: `lwasm` from PATH).
#   OS9         : toolshed `os9` binary (default: built from the
#                 vendored submodule into $(BUILD)/tools/).
#
# Targets:
#   make             - assemble all modules into ./build/
#   make tools       - build the vendored toolshed (os9/decb)
#   make boot        - build ./build/OS9Boot
#   make install     - copy OS9Boot, CMDS, and startup into $(DISK)
#   make distro      - build a fresh NitrOS-9 disk by invoking the
#                      upstream level2/coco3 makefile.  Result is at
#                      ./build/disk.dsk.
#   make fromscratch - distro + install onto the freshly built disk
#                      (no preexisting DISK image required)
#   make clean       - remove ./build/

LWASM ?= lwasm
NITROS9_SRC ?=
PRISTINE    ?=
DISK        ?=

BUILD := build
SRC   := src

# Toolshed (the `os9` utility for poking at OS-9 .dsk images) is
# vendored as a submodule and built locally into $(BUILD)/tools.
# Override OS9= on the command line if you have a different copy you'd
# rather use.
TOOLSHED_SRC := vendor/toolshed
TOOLS_DIR    := $(BUILD)/tools
OS9          ?= $(TOOLS_DIR)/os9
DECB         ?= $(TOOLS_DIR)/decb

LWFLAGS = --6809 --format=os9 \
          --pragma=pcaspcr,nosymbolcase,condundefzero,undefextern,dollarnotlocal \
          -DNOS9VER=3 -DNOS9MAJ=3 -DNOS9MIN=0 -DNOS9DBG=0 -Dcoco3=1

ifdef NITROS9_SRC
LWFLAGS += --includedir=$(NITROS9_SRC)/defs \
           --includedir=$(NITROS9_SRC)/level1/modules \
           --includedir=$(NITROS9_SRC)/level2/coco3/modules
endif

# Modules built into the boot file (loaded by the bootstrap).
BOOT_MODS = $(BUILD)/scwpt $(BUILD)/wt $(BUILD)/wt1 $(BUILD)/wt2

# Modules copied into CMDS (loaded on demand by F$Link).
CMD_MODS  = $(BUILD)/wtbridge $(BUILD)/wtping $(BUILD)/wifi

ALL_MODS  = $(BOOT_MODS) $(CMD_MODS)

# Name of the disk image the upstream NitrOS-9 level2/coco3 makefile
# produces.  The version embedded in the name comes from
# $(NITROS9_SRC)/rules.mak (NOS9VER/MAJ/MIN).  Override if your tree
# is a different release.
NITROS9_VER ?= v030300
DISTRO_DSK = nos96809l2$(NITROS9_VER)coco3_becker.dsk

.PHONY: all boot install distro fromscratch tools clean
all: $(ALL_MODS)

$(BUILD)/%: $(SRC)/%.asm | $(BUILD)
	$(LWASM) $(LWFLAGS) $< -o$@

$(BUILD):
	mkdir -p $(BUILD)

# --- toolshed bootstrap --------------------------------------------
# Build the vendored toolshed into $(TOOLS_DIR) so nothing on the
# user's PATH is required.  Touches a sentinel so subsequent make
# invocations skip the rebuild.
tools: $(TOOLS_DIR)/.built

$(TOOLS_DIR)/.built: $(TOOLSHED_SRC)/build/unix/Makefile | $(TOOLS_DIR)
	$(MAKE) -C $(TOOLSHED_SRC)/build/unix
	cp $(TOOLSHED_SRC)/build/unix/os9/os9 $(OS9)
	cp $(TOOLSHED_SRC)/build/unix/decb/decb $(DECB)
	touch $@

$(OS9) $(DECB): $(TOOLS_DIR)/.built

$(TOOLSHED_SRC)/build/unix/Makefile:
	@echo "vendor/toolshed not populated - run: git submodule update --init"
	@exit 1

$(TOOLS_DIR): | $(BUILD)
	mkdir -p $(TOOLS_DIR)

boot: $(BUILD)/OS9Boot

# Cache a pristine OS9Boot baseline.  If the user passed PRISTINE
# explicitly, just copy it; otherwise pull a fresh one from DISK
# (which must still have the stock NitrOS-9 boot installed).
$(BUILD)/OS9Boot.pristine: $(OS9) | $(BUILD)
ifdef PRISTINE
	cp $(PRISTINE) $@
else
ifndef DISK
	$(error need PRISTINE=<file> or DISK=<image> to source a baseline boot)
endif
	$(OS9) copy $(DISK),OS9Boot $@
endif

$(BUILD)/OS9Boot: $(BOOT_MODS) boot/build_boot.py $(BUILD)/OS9Boot.pristine
	boot/build_boot.py --pristine $(BUILD)/OS9Boot.pristine --out $@ $(BOOT_MODS)

install: boot $(CMD_MODS) boot/startup $(OS9)
ifndef DISK
	$(error DISK not set - point it at the target .dsk image)
endif
	$(OS9) del $(DISK),OS9Boot 2>/dev/null || true
	$(OS9) gen $(DISK) -b=$(BUILD)/OS9Boot
	$(foreach m,$(CMD_MODS),\
	  $(OS9) del $(DISK),CMDS/$(notdir $(m)) 2>/dev/null || true ; \
	  $(OS9) copy -r $(m) $(DISK),CMDS/$(notdir $(m)) ; \
	  $(OS9) attr -e -pe $(DISK),CMDS/$(notdir $(m)) ; )
	$(OS9) del $(DISK),startup 2>/dev/null || true
	$(OS9) copy boot/startup $(DISK),startup

# --- build a fresh NitrOS-9 disk from source -----------------------
# Patches the upstream tree (idempotent), runs `make all` + the
# becker-disk target, then copies the result into our build dir.
# See patches/cmds-minimal.patch for what's stripped (3rdparty
# packages absent in the stock v3.3.0 source archive + edit.asm
# which has lwasm-rejected syntax).
distro: $(BUILD)/disk.dsk

# Sentinel: presence means patches are applied to this NITROS9_SRC.
# Re-extract NitrOS-9 from its tarball if you ever want to undo them.
$(BUILD)/.patches-applied: patches/cmds-minimal.patch | $(BUILD)
ifndef NITROS9_SRC
	$(error NITROS9_SRC required to apply NitrOS-9 patches)
endif
	cd $(NITROS9_SRC) && patch -p1 --forward < $(abspath patches/cmds-minimal.patch) \
	  || test $$? -eq 1   # patch returns 1 if already applied; that's fine
	touch $@

$(BUILD)/disk.dsk: $(BUILD)/.patches-applied | $(BUILD)
	NITROS9DIR=$(NITROS9_SRC) $(MAKE) -C $(NITROS9_SRC)/level2/coco3 all
	NITROS9DIR=$(NITROS9_SRC) $(MAKE) -C $(NITROS9_SRC)/level2/coco3 $(DISTRO_DSK)
	cp $(NITROS9_SRC)/level2/coco3/$(DISTRO_DSK) $@

# One-shot: build distro then install our modules onto it.
fromscratch: distro
	$(MAKE) install DISK=$(abspath $(BUILD)/disk.dsk)

clean:
	rm -rf $(BUILD)
