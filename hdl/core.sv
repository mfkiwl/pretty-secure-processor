/*
 * core
 *
 * The main PSP processor core.
 */
`include "memory_if.sv"
`include "defines.sv"

module core
    (
        // Instruction & data memory
        mem_if.driver imem,
        mem_if.driver dmem,

        input logic reset,
        input logic clk
    );

    // Control words
    // * = the signal being read by a given stage (reg)
    // *_next = the signal being generated by the preceeding stage (combinatorial)
    // For example, execute_next is generated by decode. execute is loaded with execute_next
    // at each clock cycle.
    controlword decode, execute_next, execute, mem_next, mem, wb_next, wb;

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

    always_ff @ (posedge clk) begin
        if (reset) begin
            // Clear fetch internal state and control word for decode
            pc <= 0;
            decode.pc <= 0;
            decode.valid <= 0;
        end
        else begin
            // Update fetch internal state and control word for decode
            decode.valid <= 1;
            decode.pc <= pc;
            pc <= pc + 4;
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
            op_jal      :   execute_next.imm = execute_next.i_imm;
            op_jalr     :   execute_next.imm = execute_next.j_imm;
            op_br       :   execute_next.imm = execute_next.b_imm;
            op_load     :   execute_next.imm = execute_next.i_imm;
            op_store    :   execute_next.imm = execute_next.s_imm;
            op_imm      :   execute_next.imm = execute_next.i_imm;

            default     :   execute_next.imm = execute_next.i_imm; // Don't really care
        endcase

        // Setup ALU stuff:
        case (func3_alu'(execute_next.func3))
            func3_add   :   execute_next.alu_command = execute_next.func7[6] == 0 ? alu_add : alu_sub;
            func3_sll   :   execute_next.alu_command = alu_sll;
            func3_xor   :   execute_next.alu_command = alu_xor;
            func3_srl   :   execute_next.alu_command = execute_next.func7[6] == 0 ? alu_srl : alu_sra;
            func3_or    :   execute_next.alu_command = alu_or;
            func3_and   :   execute_next.alu_command = alu_and;

            default     :   execute_next.alu_command = alu_and; // Don't care (could optimize with gating ALU)
        endcase

        // alu_mux1 is 0 for rs1, 1 for pc
        case (execute_next.opcode)
            op_lui      :   execute_next.alu_mux1 = 0; // Technically don't care
            op_auipc    :   execute_next.alu_mux1 = 1;
            op_jal      :   execute_next.alu_mux1 = 1;
            op_jalr     :   execute_next.alu_mux1 = 1;
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

        // Setup WB stuff (do we writeback memory out? Or alu out? etc.)
        case (execute_next.opcode)
            // Load immediate value directly
            op_lui : begin
                execute_next.load_rd        =   1;
                execute_next.wb_command     =   wb_imm;
            end

            // Load return address
            op_jalr, op_jalr : begin
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
    end

    always_ff @ (posedge clk) begin
        if (reset) begin
            // Clear decode internal state

            // Clear control word for execute
            execute.valid <= 0;
        end
        else begin
            // Update decode internal state

            // Setup the control word for execute
            execute <= execute_next;
            execute.rs1_val <= regs[execute_next.rs1_idx];
            execute.rs2_val <= regs[execute_next.rs2_idx];
        end
    end

    // Register file:
    // Write into here only in wb stage
    integer i;
    always_ff @ (posedge clk) begin
        for (i = 1; i < 32 ; i++) begin
            if (reset) regs[i] <= 32'h0;
            else begin
                if (i == wb.rd_idx && wb.load_rd && wb.valid) regs[i] <= wb_val;
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

    logic[31:0] alu_in1, alu_in2, alu_out;
    alu alu_inst (
        .in1(alu_in1),
        .in2(alu_in2),
        .command(execute.alu_command),
        .alu_out(alu_out)
    );

    // Setup alu_in1 and alu_in2 based on control word
    always_comb begin
        case (execute.alu_mux1)
            0: alu_in1 = execute.rs1_val;
            1: alu_in1 = execute.pc;
        endcase

        case (execute.alu_mux2)
            0: alu_in2 = execute.rs2_val;
            1: alu_in2 = execute.imm;
        endcase
    end

    // Update anything in the control word
    always_comb begin
        mem_next = execute;
        mem_next.alu_out = alu_out;
        mem_next.cmp_out = cmp_out;
    end

    // Comparison unit
    logic cmp_out;
    cmp cmp_inst (
        .in1(execute.rs1_val),
        .in2(execute.cmp_mux == 1'b1 ? execute.imm : execute.rs2_val),
        .command(execute.cmp_command),
        .cmp_out(cmp_out)
    );
    
    always_ff @ (posedge clk) begin
        if (reset) begin
            // Clear execute internal state

            // Clear control word for mem
            mem.valid <= 0;
        end
        else begin
            // Update execute internal state

            // Setup control word for mem
            mem <= mem_next;
        end
    end

    /*
     * Memory
     *
     * Read / write to data memory
     */

    always_comb begin
        wb_next = mem;
        dmem.addr = mem.alu_out;
        dmem.data_i = mem.rs2_val;

        // @TODO: byte width stuff
        dmem.data_en = 4'b1111;

        dmem.write_en = mem.opcode == op_store;
    end

    always_ff @ (posedge clk) begin
        if (reset) begin
            // Clear mem internal state

            // Clear control word for wb
            wb.valid <= 0;
        end
        else begin
            // Update mem internal state

            // Setup control word for wb
            wb <= wb_next;
            wb.mem_out <= dmem.data_o;
        end
    end

    /*
     * Writeback
     *
     * Commit result to destination register.
     */

    // Value written back to register file:
    logic[31:0] wb_val;

    always_comb begin
        case (wb.wb_command)
            wb_alu : wb_val = wb.alu_out;
            wb_cmp : wb_val = wb.cmp_out;
            wb_mem : wb_val = wb.mem_out;
            wb_ret : wb_val = wb.pc + 4;
            wb_imm : wb_val = wb.imm;
        endcase
    end

endmodule

