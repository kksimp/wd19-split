// Pre-analysis: put the whole image in MCS-251 source mode and seed functions
// at every ECALL (9A xx yy zz) target that lands inside the loaded block.
// @category WD19

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressRange;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.ProgramContext;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import java.math.BigInteger;
import java.util.TreeSet;

public class SetSrcModeAndSeed extends GhidraScript {
	@Override
	public void run() throws Exception {
		Register src = currentProgram.getRegister("srcMode");
		if (src == null)
			throw new Exception("no srcMode context register; wrong language?");
		ProgramContext ctx = currentProgram.getProgramContext();
		Memory mem = currentProgram.getMemory();
		for (AddressRange r : mem.getAddressRanges())
			ctx.setValue(src, r.getMinAddress(), r.getMaxAddress(), BigInteger.ONE);
		// the loaded image is the largest initialized block (the language also
		// defines small register/SFR blocks that we must skip)
		MemoryBlock code = null;
		for (MemoryBlock blk : mem.getBlocks())
			if (blk.isInitialized() && (code == null || blk.getSize() > code.getSize()))
				code = blk;
		if (code == null)
			throw new Exception("no initialized block");
		Address start = code.getStart();
		long base = start.getOffset();
		long size = code.getSize();
		byte[] b = new byte[(int) size];
		code.getBytes(start, b);
		println("code block " + code.getName() + " @ " + start + " size 0x" + Long.toHexString(size));

		TreeSet<Long> seeds = new TreeSet<>();
		for (int i = 0; i + 3 < b.length; i++) {
			if ((b[i] & 0xff) != 0x9a)
				continue;
			long t = ((b[i + 1] & 0xffL) << 16) | ((b[i + 2] & 0xffL) << 8) | (b[i + 3] & 0xffL);
			if (t < base || t >= base + size)
				continue;
			if ((b[(int) (t - base)] & 0xff) != 0xca) // function prologue PUSH
				continue;
			seeds.add(t);
		}
		int made = 0;
		for (long t : seeds) {
			Address a = start.getNewAddress(t);
			new DisassembleCommand(new AddressSet(a), null, true).applyTo(currentProgram, monitor);
			if (getFunctionAt(a) == null && createFunction(a, null) != null)
				made++;
		}
		println("srcMode=1 over image; seeded " + seeds.size() + " call targets, created " + made + " functions");
	}
}
