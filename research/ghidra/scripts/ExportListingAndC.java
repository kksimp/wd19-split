// Post-analysis: write the full disassembly listing and decompiled C for every
// function to the directory given as the first script argument.
// @category WD19

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import java.io.File;
import java.io.PrintWriter;

public class ExportListingAndC extends GhidraScript {
	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		File out = new File(args.length > 0 ? args[0] : ".");
		out.mkdirs();

		int n = 0;
		try (PrintWriter w = new PrintWriter(new File(out, "listing.txt"))) {
			InstructionIterator it = currentProgram.getListing().getInstructions(true);
			while (it.hasNext() && !monitor.isCancelled()) {
				Instruction ins = it.next();
				Function f = getFunctionContaining(ins.getAddress());
				StringBuilder hex = new StringBuilder();
				for (byte x : ins.getBytes())
					hex.append(String.format("%02x", x & 0xff));
				w.printf("%s  %-12s %-28s ; %s%n", ins.getAddress(), hex, ins.toString(),
					f == null ? "" : f.getName());
				n++;
			}
		}

		DecompInterface dec = new DecompInterface();
		dec.openProgram(currentProgram);
		int ok = 0, total = 0;
		try (PrintWriter w = new PrintWriter(new File(out, "decompiled.c"))) {
			for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
				if (monitor.isCancelled())
					break;
				total++;
				DecompileResults r = dec.decompileFunction(f, 60, monitor);
				w.printf("%n/* ==== %s @ %s ==== */%n", f.getName(), f.getEntryPoint());
				if (r != null && r.decompileCompleted()) {
					w.println(r.getDecompiledFunction().getC());
					ok++;
				} else {
					w.println("/* decompile failed: " + (r == null ? "null" : r.getErrorMessage()) + " */");
				}
			}
		}
		dec.dispose();
		println("exported " + n + " instructions; decompiled " + ok + "/" + total + " functions to " + out);
	}
}
