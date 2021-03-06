/* Platform-specific definitions, and basic MMIO devices. */

/* Current constraints on this implementation are:
   - it cannot access memory directly, but instead provides definitions for the physical memory model
   - it can access system register state, needed to manipulate interrupt bits
   - it relies on externs to get platform address information and doesn't hardcode them.
*/

/* Main memory */
val plat_ram_base = {c: "plat_ram_base", ocaml: "Platform.dram_base", lem: "plat_ram_base"} : unit -> xlenbits
val plat_ram_size = {c: "plat_ram_size", ocaml: "Platform.dram_size", lem: "plat_ram_size"} : unit -> xlenbits

/* whether the MMU should update dirty bits in PTEs */
val plat_enable_dirty_update = {ocaml: "Platform.enable_dirty_update",
                                c: "plat_enable_dirty_update",
                                lem: "plat_enable_dirty_update"} : unit -> bool

/* whether the platform supports misaligned accesses without trapping to M-mode. if false,
 * misaligned loads/stores are trapped to Machine mode.
 */
val plat_enable_misaligned_access = {ocaml: "Platform.enable_misaligned_access",
                                     c: "plat_enable_misaligned_access",
                                     lem: "plat_enable_misaligned_access"} : unit -> bool

/* whether mtval stores the bits of a faulting instruction on illegal instruction exceptions */
val plat_mtval_has_illegal_inst_bits = {ocaml: "Platform.mtval_has_illegal_inst_bits",
                                        c: "plat_mtval_has_illegal_inst_bits",
                                        lem: "plat_mtval_has_illegal_inst_bits"} : unit -> bool

/* ROM holding reset vector and device-tree DTB */
val plat_rom_base   = {ocaml: "Platform.rom_base", c: "plat_rom_base", lem: "plat_rom_base"} : unit -> xlenbits
val plat_rom_size   = {ocaml: "Platform.rom_size", c: "plat_rom_size", lem: "plat_rom_size"} : unit -> xlenbits

/* Location of clock-interface, which should match with the spec in the DTB */
val plat_clint_base = {ocaml: "Platform.clint_base", c: "plat_clint_base", lem: "plat_clint_base"} : unit -> xlenbits
val plat_clint_size = {ocaml: "Platform.clint_size", c: "plat_clint_size", lem: "plat_clint_size"} : unit -> xlenbits

/* Location of HTIF ports */
val plat_htif_tohost = {ocaml: "Platform.htif_tohost", c: "plat_htif_tohost", lem: "plat_htif_tohost"} : unit -> xlenbits
// todo: fromhost

val phys_mem_segments : unit -> list((xlenbits, xlenbits))
function phys_mem_segments() =
  (plat_rom_base (), plat_rom_size ()) ::
  (plat_ram_base (), plat_ram_size ()) ::
  [||]

/* Physical memory map predicates */

function within_phys_mem forall 'n. (addr : xlenbits, width : atom('n)) -> bool = {
  /* To avoid overflow issues when physical memory extends to the end
   * of the addressable range, we need to perform address bound checks
   * with a wider bitwidth.
   *
   * But since this is a hot function, we use only 64-bit width even for
   * 64-bit mode to reduce impact on emulator performance.
   */

  let ext_addr : bits(64) = EXTZ(addr);
  let ram_base : bits(64) = EXTZ(plat_ram_base ());
  let rom_base : bits(64) = EXTZ(plat_rom_base ());
  let ram_size : bits(64) = EXTZ(plat_ram_size ());
  let rom_size : bits(64) = EXTZ(plat_rom_size ());

  /* todo: iterate over segment list */
  if (  ram_base <=_u ext_addr
      & (ext_addr + sizeof('n)) <=_u (ram_base + ram_size))
       then true
  else if (  rom_base <=_u ext_addr
           & (ext_addr + sizeof('n)) <=_u (rom_base + rom_size))
       then true
  else {
    print_platform("within_phys_mem: " ^ BitStr(addr) ^ " not within phys-mem:");
    print_platform("  plat_rom_base: " ^ BitStr(rom_base));
    print_platform("  plat_rom_size: " ^ BitStr(rom_size));
    print_platform("  plat_ram_base: " ^ BitStr(ram_base));
    print_platform("  plat_ram_size: " ^ BitStr(ram_size));
    false
  }
}

function within_clint forall 'n. (addr : xlenbits, width : atom('n)) -> bool =
    plat_clint_base() <=_u addr
  & (addr + sizeof('n)) <=_u (plat_clint_base() + plat_clint_size())

function within_htif_writable forall 'n. (addr : xlenbits, width : atom('n)) -> bool =
    plat_htif_tohost() == addr | (plat_htif_tohost() + 4 == addr & width == 4)

function within_htif_readable forall 'n. (addr : xlenbits, width : atom('n)) -> bool =
    plat_htif_tohost() == addr | (plat_htif_tohost() + 4 == addr & width == 4)

/* CLINT (Core Local Interruptor), based on Spike. */

val plat_insns_per_tick = {ocaml: "Platform.insns_per_tick", c: "plat_insns_per_tick", lem: "plat_insns_per_tick"} : unit -> int

// assumes a single hart, since this typically is a vector of per-hart registers.
register mtimecmp : bits(64)  // memory-mapped internal clint register.

/* CLINT memory-mapped IO */

/* relative address map:
 *
 * 0000 msip hart 0         -- memory-mapped software interrupt
 * 0004 msip hart 1
 * 4000 mtimecmp hart 0 lo  -- memory-mapped timer thresholds
 * 4004 mtimecmp hart 0 hi
 * 4008 mtimecmp hart 1 lo
 * 400c mtimecmp hart 1 hi
 * bff8 mtime lo            -- memory-mapped clocktimer value
 * bffc mtime hi
 */

let MSIP_BASE        : xlenbits = EXTZ(0x00000)
let MTIMECMP_BASE    : xlenbits = EXTZ(0x04000)
let MTIMECMP_BASE_HI : xlenbits = EXTZ(0x04004)
let MTIME_BASE       : xlenbits = EXTZ(0x0bff8)
let MTIME_BASE_HI    : xlenbits = EXTZ(0x0bffc)

val clint_load : forall 'n, 'n > 0. (xlenbits, int('n)) -> MemoryOpResult(bits(8 * 'n)) effect {rreg}
function clint_load(addr, width) = {
  let addr = addr - plat_clint_base ();
  /* FIXME: For now, only allow exact aligned access. */
  if addr == MSIP_BASE & ('n == 8 | 'n == 4)
  then {
    print_platform("clint[" ^ BitStr(addr) ^ "] -> " ^ BitStr(mip.MSI()));
    MemValue(sail_zero_extend(mip.MSI(), sizeof(8 * 'n)))
  }
  else if addr == MTIMECMP_BASE & ('n == 4)
  then {
    print_platform("clint<4>[" ^ BitStr(addr) ^ "] -> " ^ BitStr(mtimecmp[31..0]));
    /* FIXME: Redundant zero_extend currently required by Lem backend */
    MemValue(sail_zero_extend(mtimecmp[31..0], 32))
  }
  else if addr == MTIMECMP_BASE & ('n == 8)
  then {
    print_platform("clint<8>[" ^ BitStr(addr) ^ "] -> " ^ BitStr(mtimecmp));
    /* FIXME: Redundant zero_extend currently required by Lem backend */
    MemValue(sail_zero_extend(mtimecmp, 64))
  }
  else if addr == MTIMECMP_BASE_HI & ('n == 4)
  then {
    print_platform("clint-hi<4>[" ^ BitStr(addr) ^ "] -> " ^ BitStr(mtimecmp[63..32]));
    /* FIXME: Redundant zero_extend currently required by Lem backend */
    MemValue(sail_zero_extend(mtimecmp[63..32], 32))
  }
  else if addr == MTIME_BASE & ('n == 4)
  then {
    print_platform("clint[" ^ BitStr(addr) ^ "] -> " ^ BitStr(mtime));
    MemValue(sail_zero_extend(mtime[31..0], 32))
  }
  else if addr == MTIME_BASE & ('n == 8)
  then {
    print_platform("clint[" ^ BitStr(addr) ^ "] -> " ^ BitStr(mtime));
    MemValue(sail_zero_extend(mtime, 64))
  }
  else if addr == MTIME_BASE_HI & ('n == 4)
  then {
    print_platform("clint[" ^ BitStr(addr) ^ "] -> " ^ BitStr(mtime));
    MemValue(sail_zero_extend(mtime[63..32], 32))
  }
  else {
    print_platform("clint[" ^ BitStr(addr) ^ "] -> <not-mapped>");
    MemException(E_Load_Access_Fault)
  }
}

function clint_dispatch() -> unit = {
  print_platform("clint::tick mtime <- " ^ BitStr(mtime));
  mip->MTI() = false;
  if mtimecmp <=_u mtime then {
    print_platform(" clint timer pending at mtime " ^ BitStr(mtime));
    mip->MTI() = true
  }
}

/* The rreg effect is due to checking mtime. */
val clint_store: forall 'n, 'n > 0. (xlenbits, int('n), bits(8 * 'n)) -> MemoryOpResult(bool) effect {rreg,wreg}
function clint_store(addr, width, data) = {
  let addr = addr - plat_clint_base ();
  if addr == MSIP_BASE & ('n == 8 | 'n == 4) then {
    print_platform("clint[" ^ BitStr(addr) ^ "] <- " ^ BitStr(data) ^ " (mip.MSI <- " ^ BitStr(data[0]) ^ ")");
    mip->MSI() = data[0] == 0b1;
    clint_dispatch();
    MemValue(true)
  } else if addr == MTIMECMP_BASE & 'n == 8 then {
    print_platform("clint<8>[" ^ BitStr(addr) ^ "] <- " ^ BitStr(data) ^ " (mtimecmp)");
    mtimecmp = sail_zero_extend(data, 64); /* FIXME: Redundant zero_extend currently required by Lem backend */
    clint_dispatch();
    MemValue(true)
  } else if addr == MTIMECMP_BASE & 'n == 4 then {
    print_platform("clint<4>[" ^ BitStr(addr) ^ "] <- " ^ BitStr(data) ^ " (mtimecmp)");
    mtimecmp = vector_update_subrange(mtimecmp, 31, 0, sail_zero_extend(data, 32));  /* FIXME: Redundant zero_extend currently required by Lem backend */
    clint_dispatch();
    MemValue(true)
  } else if addr == MTIMECMP_BASE_HI & 'n == 4 then {
    print_platform("clint<4>[" ^ BitStr(addr) ^ "] <- " ^ BitStr(data) ^ " (mtimecmp)");
    mtimecmp = vector_update_subrange(mtimecmp, 63, 32, sail_zero_extend(data, 32)); /* FIXME: Redundant zero_extend currently required by Lem backend */
    clint_dispatch();
    MemValue(true)
  } else {
    print_platform("clint[" ^ BitStr(addr) ^ "] <- " ^ BitStr(data) ^ " (<unmapped>)");
    MemException(E_SAMO_Access_Fault)
  }
}

val tick_clock : unit -> unit effect {rreg, wreg}
function tick_clock() = {
  mcycle = mcycle + 1;
  mtime  = mtime  + 1;
  clint_dispatch()
}

/* Basic terminal character I/O. */

val plat_term_write = {ocaml: "Platform.term_write", c: "plat_term_write", lem: "plat_term_write"} : bits(8) -> unit
val plat_term_read  = {ocaml: "Platform.term_read",  c: "plat_term_read", lem: "plat_term_read"}  : unit -> bits(8)

/* Spike's HTIF device interface, which multiplexes the above MMIO devices. */

bitfield htif_cmd : bits(64) = {
  device  : 63 .. 56,
  cmd     : 55 .. 48,
  payload : 47 .. 0
}

register htif_tohost : bits(64)
register htif_done   : bool
register htif_exit_code : bits(64)


/* Since the htif tohost port is only available at a single address,
 * we'll assume here that physical memory model has correctly
 * dispatched the address.
 */

val htif_load : forall 'n, 'n > 0. (xlenbits, int('n)) -> MemoryOpResult(bits(8 * 'n)) effect {rreg}
function htif_load(addr, width) = {
  print_platform("htif[" ^ BitStr(addr) ^ "] -> " ^ BitStr(htif_tohost));
  /* FIXME: For now, only allow the expected access widths. */
  if      width == 8 & (addr == plat_htif_tohost())
  then    MemValue(sail_zero_extend(htif_tohost, 64))         /* FIXME: Redundant zero_extend currently required by Lem backend */
  else if width == 4 & addr == plat_htif_tohost()
  then    MemValue(sail_zero_extend(htif_tohost[31..0], 32))  /* FIXME: Redundant zero_extend currently required by Lem backend */
  else if width == 4 & addr == plat_htif_tohost() + 4
  then    MemValue(sail_zero_extend(htif_tohost[63..32], 32)) /* FIXME: Redundant zero_extend currently required by Lem backend */
  else    MemException(E_Load_Access_Fault)
}

/* The rreg,wreg effects are an artifact of using 'register' to implement device state. */
val htif_store: forall 'n, 0 < 'n <= 8. (xlenbits, int('n), bits(8 * 'n)) -> MemoryOpResult(bool) effect {rreg,wreg}
function htif_store(addr, width, data) = {
  print_platform("htif[" ^ BitStr(addr) ^ "] <- " ^ BitStr(data));
  /* Store the written value so that we can ack it later. */
  if      width == 8
  then    { htif_tohost = EXTZ(data) }
  else if width == 4 & addr == plat_htif_tohost()
  then    { htif_tohost = vector_update_subrange(htif_tohost, 31, 0, data) }
  else if width == 4 & addr == plat_htif_tohost() + 4
  then    { htif_tohost = vector_update_subrange(htif_tohost, 63, 32, data) }
  else    { htif_tohost = EXTZ(data) };

  /* Process the cmd immediately; this is needed for terminal output. */
  let cmd = Mk_htif_cmd(htif_tohost);
  match cmd.device() {
    0x00 => { /* syscall-proxy */
      print_platform("htif-syscall-proxy cmd: " ^ BitStr(cmd.payload()));
      if cmd.payload()[0] == 0b1
      then {
           htif_done = true;
           htif_exit_code = (sail_zero_extend(cmd.payload(), 64) >> 0b01)
      }
      else ()
    },
    0x01 => { /* terminal */
      print_platform("htif-term cmd: " ^ BitStr(cmd.payload()));
      match cmd.cmd() {
        0x00 => /* TODO: terminal input handling */ (),
        0x01 => plat_term_write(cmd.payload()[7..0]),
        c    => print("Unknown term cmd: " ^ BitStr(c))
      }
    },
    d => print("htif-???? cmd: " ^ BitStr(data))
  };
  MemValue(true)
}

val htif_tick : unit -> unit effect {rreg, wreg}
function htif_tick() = {
  print_platform("htif::tick " ^ BitStr(htif_tohost));
  htif_tohost = EXTZ(0b0)  /* htif ack */
}

/* Top-level MMIO dispatch */

function within_mmio_readable forall 'n. (addr : xlenbits, width : atom('n)) -> bool =
  within_clint(addr, width) | (within_htif_readable(addr, width) & 1 <= 'n)

function within_mmio_writable forall 'n. (addr : xlenbits, width : atom('n)) -> bool =
  within_clint(addr, width) | (within_htif_writable(addr, width) & 'n <= 8)

function mmio_read forall 'n, 'n > 0. (addr : xlenbits, width : atom('n)) -> MemoryOpResult(bits(8 * 'n)) =
  if   within_clint(addr, width)
  then clint_load(addr, width)
  else if within_htif_readable(addr, width) & (1 <= 'n)
  then htif_load(addr, width)
  else MemException(E_Load_Access_Fault)

function mmio_write forall 'n, 'n > 0. (addr : xlenbits, width : atom('n), data: bits(8 * 'n)) -> MemoryOpResult(bool) =
  if   within_clint(addr, width)
  then clint_store(addr, width, data)
  else if within_htif_writable(addr, width) & 'n <= 8
  then htif_store(addr, width, data)
  else MemException(E_SAMO_Access_Fault)

/* Platform initialization and ticking. */

function init_platform() -> unit = {
  htif_tohost = EXTZ(0b0);
  htif_done   = false;
  htif_exit_code = EXTZ(0b0)
}

function tick_platform() -> unit = {
  htif_tick();
}

/* Platform-specific handling of instruction faults */

function handle_illegal() -> unit = {
  let info = if plat_mtval_has_illegal_inst_bits ()
             then Some(instbits)
             else None();
  let t : sync_exception = struct { trap    = E_Illegal_Instr,
                                    excinfo = info };
  nextPC = handle_exception(cur_privilege, CTL_TRAP(t), PC)
}

/* Platform-specific wait-for-interrupt */

function platform_wfi() -> unit = {
  cancel_reservation();
  /* speed execution by getting the timer to fire at the next instruction,
   * since we currently don't have any other devices raising interrupts.
   */
  if mtime <_u mtimecmp then {
    mtime  = mtimecmp;
    mcycle = mtimecmp;
  }
}
