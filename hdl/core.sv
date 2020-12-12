/*
 * core
 *
 * The main PSP processor core.
 */
`include "defines.sv"
`include "memory_if.sv"
`include "rvfi_if.sv"

module core
    (
        // Instruction & data memory
        mem_if.driver imem,
        mem_if.driver dmem,

        // RVFI attachment
        output rvfi_if rvfi_out,

        input logic reset,
        input logic clk
    );

    // Control words
    // * = the signal being read by a given stage (reg)
    // *_next = the signal being generated by the preceeding stage (combinatorial)
    // For example, execute_next is generated by decode. execute is loaded with execute_next
    // at each clock cycle.
    controlword decode_next, decode, execute_next, execute, mem_next, mem, wb_next, wb;

    // Registers
    logic [31:0] regs[32];
    logic [31:0] pc;

    /*
     * Fetch
     *
     * Requests next instruction from memory- this instruction
     * will be available in decode stage as "imem.data_o".
     *
     * Also calculates next PC and assigns PC to new value.
     */
    assign imem.addr = pc;
    assign imem.write_en = 0;
    assign imem.data_en = 4'b1111;
    assign imem.data_i = 0;

    // When stalling we need to save old imem because memory is behind a single cycle:
    logic[31:0] old_imem;
    logic[2:0] old_stall_stage; // Were we stalling last cycle? (If this is true and stalling is false, read from old imem)

    always_ff @ (posedge clk) begin
        old_stall_stage <= stall_stage;
        old_imem <= imem.data_o;
    end

    always_comb begin
        decode_next.pc = pc;
        decode_next.valid = !reset;
    end

    always_ff @ (posedge clk) begin
        if (reset) begin
            pc <= 0;
        end
        else begin
            // Only progress pc if we aren't stalling fetch
            if (stall_stage < 1) begin
                if (branching)
                    pc <= branch_target;
                else
                    pc <= pc + 4;
            end
        end
    end

    /*
     * Decode
     *
     * Load rs1 and rs2 from regfile, handle forwarding,
     * and get control word ready for execute.
     *
     * (Instruction is in imem.data_o)
     */

    // Current instruction in decode (just makes code easier to read):
    logic[31:0] d_instr;

    always_comb begin
        execute_next = decode;

        execute_next.instruction = imem.data_o;
        if (stall_stage == 0 && old_stall_stage > 0) begin
            execute_next.instruction = old_imem;
        end

        d_instr = execute_next.instruction;

        // Decode opcode:
        execute_next.rs1_idx = d_instr[19:15];
        execute_next.rs2_idx = d_instr[24:20];
        execute_next.rd_idx = d_instr[11:7];
        execute_next.opcode = rv_opcode'(d_instr[6:0]);
        execute_next.func7 = d_instr[31:25];
        execute_next.func3 = d_instr[14:12];
        execute_next.i_imm = { {20{d_instr[31]}}, d_instr[31:20]};
        execute_next.s_imm = { {20{d_instr[31]}}, d_instr[31:25], d_instr[11:7]};
        execute_next.b_imm = { {19{d_instr[31]}}, d_instr[31], d_instr[7], d_instr[30:25], d_instr[11:8], 1'b0};
        execute_next.u_imm = { d_instr[31:12], {12{1'b0}}};
        execute_next.j_imm = { {11{d_instr[31]}}, d_instr[31], d_instr[19:12], d_instr[20], d_instr[30:21], 1'b0};

        case (execute_next.opcode)
            op_lui      :   execute_next.imm = execute_next.u_imm;
            op_auipc    :   execute_next.imm = execute_next.u_imm;
            op_jal      :   execute_next.imm = execute_next.j_imm;
            op_jalr     :   execute_next.imm = execute_next.i_imm;
            op_br       :   execute_next.imm = execute_next.b_imm;
            op_load     :   execute_next.imm = execute_next.i_imm;
            op_store    :   execute_next.imm = execute_next.s_imm;
            op_imm      :   execute_next.imm = execute_next.i_imm;

            default     :   execute_next.imm = execute_next.i_imm; // Don't really care
        endcase

        // Setup ALU stuff:
        // If the instruction isn't an immediate or reg op, set ALU to add (always add for MEM instructions,
        // AUIPC, JALR, etc.)
        execute_next.alu_command = alu_add;
        if (execute_next.opcode == op_imm || execute_next.opcode == op_reg) begin
            case (func3_alu'(execute_next.func3))
                // For op_reg sub we fix this later:
                func3_add   :   execute_next.alu_command = alu_add;
                func3_sll   :   execute_next.alu_command = alu_sll;
                func3_xor   :   execute_next.alu_command = alu_xor;
                func3_srl   :   execute_next.alu_command = execute_next.func7[6] == 0 ? alu_srl : alu_sra;
                func3_or    :   execute_next.alu_command = alu_or;
                func3_and   :   execute_next.alu_command = alu_and;

                default     :   execute_next.alu_command = alu_add; // Don't care (could optimize with gating ALU)
            endcase
        end

        // Only op reg supports sub
        if (execute_next.opcode == op_reg) begin
            if (func3_alu'(execute_next.func3) == func3_add) begin
                execute_next.alu_command = execute_next.func7[6] == 0 ? alu_add : alu_sub;
            end
        end

        // alu_mux1 is 0 for rs1, 1 for pc
        case (execute_next.opcode)
            op_lui      :   execute_next.alu_mux1 = 0; // Technically don't care
            op_auipc    :   execute_next.alu_mux1 = 1;
            op_jal      :   execute_next.alu_mux1 = 1;
            op_jalr     :   execute_next.alu_mux1 = 0;
            op_br       :   execute_next.alu_mux1 = 1;
            op_load     :   execute_next.alu_mux1 = 0;
            op_store    :   execute_next.alu_mux1 = 0;
            op_imm      :   execute_next.alu_mux1 = 0;
            op_reg      :   execute_next.alu_mux1 = 0;

            default     :   execute_next.alu_mux1 = 0;
        endcase

        // alu_mux2 is 0 for rs2, 1 for imm
        case (execute_next.opcode)
            op_lui      :   execute_next.alu_mux2 = 0; // Technically don't care
            op_auipc    :   execute_next.alu_mux2 = 1;
            op_jal      :   execute_next.alu_mux2 = 1;
            op_jalr     :   execute_next.alu_mux2 = 1;
            op_br       :   execute_next.alu_mux2 = 1;
            op_load     :   execute_next.alu_mux2 = 1;
            op_store    :   execute_next.alu_mux2 = 1;
            op_imm      :   execute_next.alu_mux2 = 1;
            op_reg      :   execute_next.alu_mux2 = 0;

            default     :   execute_next.alu_mux2 = 0;
        endcase

        // Setup CMP stuff:
        case (execute_next.opcode)
            op_br       :   execute_next.cmp_command = cmp_cmd'(execute_next.func3);

            op_imm, op_reg : begin
                execute_next.cmp_command = execute_next.func3[0] == 0 ? cmp_lt : cmp_ltu;
            end

            default     :   execute_next.cmp_command = cmp_eq; // Don't care (could optimize with gating CMP)
        endcase
        execute_next.cmp_mux = execute_next.opcode == op_imm ? 1 : 0; // rs2 if not op_imm, otherwise imm
        
        // Setup MEM stuff (do we read/ write?):
        // Mask gets recalculated later on when we know address, for now just set it to 0:
        execute_next.mem_mask = 4'b0000;

        // Setup WB stuff (do we writeback memory out? Or alu out? etc.)
        case (execute_next.opcode)
            // Load immediate value directly
            op_lui : begin
                execute_next.load_rd        =   1;
                execute_next.wb_command     =   wb_imm;
            end

            // Load return address
            op_jal, op_jalr : begin
                execute_next.load_rd        =   1;
                execute_next.wb_command     =   wb_ret;
            end

            // Load from memory
            op_load     :   begin
                execute_next.load_rd        =   1;
                execute_next.wb_command     =   wb_mem;
            end

            // Always load ALU
            op_auipc : begin
                execute_next.load_rd        =   1;
                execute_next.wb_command     =   wb_alu;
            end

            // Load ALU or CMP output
            op_imm, op_reg : begin
                execute_next.load_rd        =   1;
                execute_next.wb_command     =   wb_alu;

                if (execute_next.func3 == func3_slt || execute_next.func3 == func3_sltu) begin
                    execute_next.wb_command = wb_cmp;
                end
            end

            default : begin
                execute_next.load_rd        =   0;
                execute_next.wb_command     =   wb_alu;
            end
        endcase

        execute_next.rs1_val = regs[execute_next.rs1_idx];
        execute_next.rs2_val = regs[execute_next.rs2_idx];

        // If WB is about to rewrite RS1 or RS2 just forward that onto EX:
        if (wb.valid && wb.load_rd && wb.rd_idx == execute_next.rs1_idx && wb.rd_idx != 0)
            execute_next.rs1_val = wb_val;
        if (wb.valid && wb.load_rd && wb.rd_idx == execute_next.rs2_idx && wb.rd_idx != 0)
            execute_next.rs2_val = wb_val;

        // RVFI stuff:
        execute_next.pc_next = pc;
    end

    // Register file:
    // Write into here only in wb stage
    integer i;
    always_ff @ (posedge clk) begin
        for (i = 1; i < 32 ; i++) begin
            if (reset) regs[i] <= 32'h0;
            else begin
                if (i == wb.rd_idx && wb.load_rd && wb.valid && stall_stage < 5) regs[i] <= wb_val;
            end
        end
    end
    assign regs[0] = 32'h0;

    /*
     * Execute
     *
     * Do some math on rs1 and rs2, or maybe
     * calculate an address to be used in Memory stage.
     */

    // Are we branching this cycle?
    // If so, need to invalidate current fetch and decode
    logic branching;
    logic[31:0] branch_target;

    // Does execute need to stall?
    logic ex_hazard_stall;

    logic[31:0] alu_in1, alu_in2, alu_out;
    alu alu_inst (
        .in1(alu_in1),
        .in2(alu_in2),
        .command(execute.alu_command),
        .alu_out(alu_out)
    );

    // "Effective" rs1 and rs2 (with hazards detected):
    logic[31:0] ex_rs1_val, ex_rs2_val;

    // Hazard detection
    always_comb begin
        ex_rs1_val = execute.rs1_val;
        ex_rs2_val = execute.rs2_val;
        ex_hazard_stall = 1'b0;

        // Check for hazards we can overcome:
        // (Don't forward x0, it's always just 0)
        if (wb.load_rd && wb.valid && wb.rd_idx == execute.rs1_idx && wb.rd_idx != 0) begin
            ex_rs1_val = wb_val;
        end
        if (wb.load_rd && wb.valid && wb.rd_idx == execute.rs2_idx && wb.rd_idx != 0) begin
            ex_rs2_val = wb_val;
        end

        // Check for stall-worthy hazards:
        // (Don't forward x0, it's always just 0)
        // @TODO: Only stall if these signals are actually needed
        if (execute.valid) begin
            // Only stall if we are actually valid
            if (mem.load_rd && mem.valid && mem.rd_idx == execute.rs1_idx && mem.rd_idx != 0) begin
                // $display("Stalling due to hazard on rs1 (x%d)", execute.rs1_idx);
                ex_hazard_stall = 1;
            end
            if (mem.load_rd && mem.valid && mem.rd_idx == execute.rs2_idx && mem.rd_idx != 0) begin
                // $display("Stalling due to hazard on rs2 (x%d)", execute.rs2_idx);
                ex_hazard_stall = 1;
            end
        end
    end

    // Setup alu_in1 and alu_in2 based on control word
    always_comb begin
        case (execute.alu_mux1)
            // rs1
            0: alu_in1 = ex_rs1_val;

            // pc
            1: alu_in1 = execute.pc;
        endcase

        case (execute.alu_mux2)
            // rs2
            0: alu_in2 = ex_rs2_val;

            // imm
            1: alu_in2 = execute.imm;
        endcase
    end

    always_comb begin
        // Check for branch
        branching = 0;
        branch_target = alu_out;
        if (execute.valid) begin
            // Only flush if we are actually valid
            if (execute.opcode == op_br) begin
                branching = cmp_out;
            end

            if (execute.opcode == op_jal || execute.opcode == op_jalr) begin
                branching = 1'b1;
            end

            // if (branching) $display("[%0h] Branching to %0h", execute.pc, branch_target);
        end

        // Update anything in the control word
        mem_next = execute;
        mem_next.alu_out = alu_out;
        mem_next.cmp_out = cmp_out;
        mem_next.rs1_val = ex_rs1_val;
        mem_next.rs2_val = ex_rs2_val;

        // Update RVFI word
        if (branching) begin
            mem_next.pc_next = branch_target;
        end
    end

    // Comparison unit
    logic cmp_out;
    cmp cmp_inst (
        .in1(ex_rs1_val),
        .in2(execute.cmp_mux == 1'b1 ? execute.imm : ex_rs2_val),
        .command(execute.cmp_command),
        .cmp_out(cmp_out)
    );

    /*
     * Memory
     *
     * Read / write to data memory
     */

    always_comb begin
        wb_next = mem;
        dmem.addr = {mem.alu_out[31:2], 2'b00};
        dmem.data_i = mem.rs2_val;

        // Technically only loads can use unsigned, so in theory store should never
        // have func3_ubyte or func3_uhalf. So this is safe.
        dmem.data_en = 4'b0000;
        dmem.write_en = 0;

        if (mem.valid) begin
            // Only actually talk to memory if we are valid
            if (mem.opcode == op_load || mem.opcode == op_store) begin
                case (func3_mem'(mem.func3))
                    func3_byte, func3_ubyte      :   dmem.data_en = 4'b0001 << mem.alu_out[1:0];
                    func3_half, func3_uhalf      :   dmem.data_en = 4'b0011 << {mem.alu_out[1], 1'b0};
                    func3_word      :   dmem.data_en = 4'b1111;
                endcase
            end

            if (mem.opcode == op_store) begin
                // Shift memory data in if necessary
                case (func3_mem'(mem.func3))
                    func3_byte, func3_ubyte : begin
                        dmem.data_i = ((dmem.data_i & 32'h00_00_00_ff) << {mem.alu_out[1:0], 3'b0});
                    end

                    func3_half, func3_uhalf : begin
                        dmem.data_i = ((dmem.data_i & 32'h00_00_ff_ff) << {mem.alu_out[1], 4'b0});
                    end
                endcase
            end

            dmem.write_en = mem.opcode == op_store;
        end

        // Pass signals along for RVFI:
        wb_next.dmem_mask = dmem.data_en;
        wb_next.dmem_write_en = dmem.write_en;
        wb_next.dmem_wdata = dmem.data_i;
    end

    /*
     * Writeback
     *
     * Commit result to destination register.
     */

    // Value written back to register file:
    logic[31:0] wb_val;

    // Value from memory used in writeback. This is dmem.data_o but possibly shifted
    // Recall that dmem.data_o is combinatorially read as it is a cycle late (not latched in mem->wb stage reg)
    logic[31:0] wb_mem_val;

    always_comb begin
        wb_mem_val = dmem.data_o;
        if (wb.opcode == op_load || wb.opcode == op_store) begin
            // Zero extend by default
            case (func3_mem'(wb.func3))
                func3_byte, func3_ubyte : begin
                    wb_mem_val = (wb_mem_val >> {wb.alu_out[1:0], 3'b0}) & 32'h00_00_00_ff;
                end

                func3_half, func3_uhalf : begin
                    wb_mem_val = (wb_mem_val >> {wb.alu_out[1], 4'b0}) & 32'h00_00_ff_ff;
                end
            endcase

            // Sign extend where necessary
            if (func3_mem'(wb.func3) == func3_byte) begin
                wb_mem_val = {{24{wb_mem_val[7]}}, wb_mem_val[7:0]};
            end

            if (func3_mem'(wb.func3) == func3_half) begin
                wb_mem_val = {{16{wb_mem_val[15]}}, wb_mem_val[15:0]};
            end
        end

        case (wb.wb_command)
            wb_alu : wb_val = wb.alu_out;
            wb_cmp : wb_val = wb.cmp_out;
            wb_mem : wb_val = wb_mem_val;
            wb_ret : wb_val = wb.pc + 4;
            wb_imm : wb_val = wb.imm;
            default : wb_val = wb.alu_out;
        endcase

        if (wb.rd_idx == 0) wb_val = 0;

        if (!wb.valid) begin
            wb.load_rd = 0;
        end
    end

    // Formal verification stuff:
    always_comb begin
        // RVFI signals:
        rvfi_out.valid = wb.valid;
        rvfi_out.insn = wb.instruction;
        rvfi_out.rs1_addr = wb.rs1_idx;
        rvfi_out.rs2_addr = wb.rs2_idx;
        rvfi_out.rs1_rdata = wb.rs1_val;
        rvfi_out.rs2_rdata = wb.rs2_val;
        rvfi_out.rd_addr = wb.load_rd ? wb.rd_idx : 0;
        rvfi_out.rd_wdata = wb.load_rd ? wb_val : 0;
        rvfi_out.pc_rdata = wb.pc;
        rvfi_out.pc_wdata = wb.pc_next;
        rvfi_out.mem_addr = {wb.alu_out[31:2], 2'b00};
        rvfi_out.mem_rmask = wb.opcode == op_load ? wb.dmem_mask : 4'b0000;
        rvfi_out.mem_wmask = wb.opcode == op_store ? wb.dmem_mask : 4'b0000;
        rvfi_out.mem_rdata = wb_mem_val;
        rvfi_out.mem_wdata = wb.dmem_wdata;
    end

    // Flushing and stalling:
    /*
     * pipeline_flush[0]: invalidate current fetch
     * pipeline_flush[1]: invalidate current decode
     * pipeline_flush[2]: invalidate current execute
     * pipeline_flush[3]: invalidate current memory
     * Can't invalidate writeback stage, its too late by then!
     */
    logic [3:0] pipeline_flush;

    /*
     * stall_stage
     *
     * Stage at which the pipeline must be stalled.
     * Every stage <= stall_stage will not progress.
     * NOTE: This includes internal stage state!! (Fetch shouldn't change PC while stalled).
     *
     * Internal state to consider:
     *  fetch PC (DONE)
     *  memory writing to IO devices (@TODO)
     *  writeback modifying register file (DONE)
     *
     * stall_stage == 3'b000 (0): Stall nothing
     * stall_stage == 3'b001 (1): Stall fetch
     * stall_stage == 3'b010 (2): Stall fetch and decode
     * stall_stage == 3'b011 (3): Stall fetch, decode, execute
     * stall_stage == 3'b100 (4): Stall fetch, decode, execute, memory
     * stall_stage == 3'b101 (5): Stall entire pipeline
     */
    logic [2:0] stall_stage;

    always_comb begin
        stall_stage = 0;

        // Execute detected a hazard that requires stalling!
        if (ex_hazard_stall) stall_stage = 3; // Stall fetch, decode, execute
    end

    always_comb begin
        pipeline_flush = 4'b0000;

        if (branching) begin
            // Invalidate fetch and decode
            pipeline_flush[0] = 1'b1;
            pipeline_flush[1] = 1'b1;
        end
    end

    // Stage latching:
    always_ff @ (posedge clk) begin
        if (reset) begin
            decode.valid <= 0;
            execute.valid <= 0;
            mem.valid <= 0;
            wb.valid <= 0;
        end
        else begin
            // stall_stage of 0 means no stalling. Otherwise we stall various parts of the pipeline
            if (stall_stage < 1) decode <= decode_next;
            if (stall_stage < 2) execute <= execute_next;
            if (stall_stage < 3) mem <= mem_next;
            if (stall_stage < 4) wb <= wb_next;
            // if stall_stage < 5 wb will not do anything internally to change state

            // Inject bubbles after stalled stages:
            if (stall_stage == 1) decode.valid <= 1'b0;
            if (stall_stage == 2) execute.valid <= 1'b0;
            if (stall_stage == 3) mem.valid <= 1'b0;
            if (stall_stage == 4) wb.valid <= 1'b0;

            if (pipeline_flush[0]) decode.valid <= 1'b0;
            if (pipeline_flush[1]) execute.valid <= 1'b0;
            if (pipeline_flush[2]) mem.valid <= 1'b0;
            if (pipeline_flush[3]) wb.valid <= 1'b0;
        end
    end

endmodule

