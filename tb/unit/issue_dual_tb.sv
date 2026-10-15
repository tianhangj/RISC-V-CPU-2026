`timescale 1ns/1ps
module issue_dual_tb;
    localparam integer RW=3, PW=6, CIDW=1, MIDW=2;
    localparam integer AB=RW+CIDW+6+3*PW+64, MB=RW+3+MIDW+2*PW+32;
    localparam integer AE=RW+CIDW+6+PW+128, ME=RW+3+MIDW+96;
    reg clock=0;
    always #5 clock=~clock;
    reg reset=1, squash_valid=0, alu_cand_valid=0, mem_cand_valid=0;
    reg [RW-1:0] squash_tag=0, rob_head=0;
    reg [AB-1:0] alu_cand_uop=0;
    reg [MB-1:0] mem_cand_uop=0;
    reg alu_exec_ready=0, mul_exec_ready=0, mem_exec_ready=0;
    reg [2:0] forward_valid=0;
    reg [3*PW-1:0] forward_pdst=0;
    reg [95:0] forward_value=0;
    wire alu_cand_take, mem_cand_take, alu_exec_valid, mul_exec_valid, mem_exec_valid;
    wire [4*PW-1:0] rd_addr;
    wire [AE-1:0] alu_exec_payload;
    wire [ME-1:0] mem_exec_payload;
    issue #(.ISSUE_WIDTH(2), .ROB_DEPTH(8), .PRF_SIZE(40), .LQ_DEPTH(3), .SQ_DEPTH(4), .CHECKPOINT_DEPTH(2)) dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .alu_cand_valid, .mem_cand_valid, .mem_cand_src2_ready(1'b1),
        .alu_cand_uop, .mem_cand_uop, .alu_cand_take, .mem_cand_take,
        .rd_addr, .rd_data({32'd44,32'd33,32'd22,32'd11}),
        .forward_valid, .forward_pdst, .forward_value,
        .mem_store_data_valid(), .mem_store_psrc(), .branch_exec_valid(),
        .branch_operand1(), .branch_operand2(), .early_wake_valid(), .early_wake_pdst(),
        .alu_exec_valid, .mul_exec_valid, .mem_exec_valid, .mem_exec_preview_valid(),
        .alu_exec_ready, .mul_exec_ready, .mem_exec_ready,
        .alu_exec_payload, .mul_exec_payload(), .mem_exec_payload);
    task tick;
        begin @(posedge clock); #1; end
    endtask
    initial begin
        tick; @(negedge clock); reset=0;
        alu_cand_uop={3'd0,1'b0,6'd20,6'd32,6'd1,6'd2,32'd0,32'd0};
        mem_cand_uop={3'd1,3'd7,2'd0,6'd3,6'd4,32'd16};
        alu_cand_valid=1; mem_cand_valid=1; #1;
        if (!alu_cand_take || !mem_cand_take || rd_addr!={6'd4,6'd3,6'd2,6'd1})
            $fatal(1,"two simultaneous candidates and independent PRF addresses");
        tick; alu_cand_valid=0; mem_cand_valid=0; #1;
        if (!alu_exec_valid || !mem_exec_valid || alu_exec_payload[63:0]!={32'd11,32'd22} ||
            mem_exec_payload[95:0]!={32'd33,32'd16,32'd44}) $fatal(1,"operand capture");
        forward_valid=1; forward_pdst[0 +: PW]=1; forward_value[31:0]=99;
        tick; forward_valid=0; tick;
        if (alu_exec_payload[63:32]!=99 || mem_exec_payload[95:64]!=33)
            $fatal(1,"forwarded operand retention during backpressure");
        squash_valid=1; squash_tag=0; #1;
        if (!alu_exec_valid || mem_exec_valid) $fatal(1,"squash must preserve only the older slot");
        tick; squash_valid=0; #1;
        if (mem_exec_valid || !alu_exec_valid) $fatal(1,"squash slot state");
        alu_exec_ready=1; tick;
        if (alu_exec_valid) $fatal(1,"execution handshake");
        $display("PASS issue_dual: simultaneous issue PRF capture forwarding backpressure squash");
        $finish;
    end
    initial begin #1000; $fatal(1,"timeout"); end
endmodule
