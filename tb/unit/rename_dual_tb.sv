`timescale 1ns/1ps
module rename_dual_tb;
    localparam integer RW=3, PW=6, CIDW=1, MIDW=2;
    localparam integer AB=RW+CIDW+6+3*PW+64, MB=RW+3+MIDW+2*PW+32;
    reg clock=0;
    always #5 clock=~clock;
    reg reset=1, squash_valid=0, decode_valid=0, disp_ready=0;
    reg [116:0] decode_uop=0;
    reg [3:0] rob_free=8;
    reg [2:0] rob_tail=0;
    reg [1:0] cp_release_mask=0;
    reg [2:0] wake_valid=0;
    reg [17:0] wake_pdst=0;
    reg [1:0] reg_commit_valid=0;
    reg [11:0] reg_commit_payload=0;
    wire decode_ready, disp_valid, cp_alloc_valid, front_redirect_valid;
    wire [1:0] disp_count, disp_src1_ready, disp_src2_ready;
    wire [19:0] disp_rob;
    wire [AB-1:0] disp_alu;
    wire [MB-1:0] disp_mem;
    wire [11:0] disp_lsq;
    wire [35:0] cp_alloc_payload;
    wire [31:0] front_redirect_pc;
    rename_dual #(.ROB_DEPTH(8), .PRF_SIZE(40), .LQ_DEPTH(3), .SQ_DEPTH(4), .CHECKPOINT_DEPTH(2)) dut (
        .clock, .reset, .squash_valid, .restore_cp_id(1'b0), .cp_release_mask,
        .cp_has_free(1'b1), .cp_alloc_id(1'b0), .decode_valid, .decode_ready, .decode_uop,
        .rob_free, .rob_tail, .alu_iq_has_free(1'b1), .mem_iq_has_free(1'b1),
        .lq_has_free(1'b1), .sq_has_free(1'b1), .lq_alloc_id(2'd1), .sq_alloc_id(2'd2),
        .disp_valid, .disp_ready, .disp_count, .disp_rob, .disp_alu, .disp_mem, .disp_lsq,
        .disp_src1_ready, .disp_src2_ready, .cp_alloc_valid, .cp_alloc_payload,
        .front_redirect_valid, .front_redirect_pc,
        .wake_valid, .wake_pdst, .reg_commit_valid, .reg_commit_payload);
    task tick;
        begin @(posedge clock); #1; end
    endtask
    task initialize;
        begin
            @(negedge clock); reset=1; decode_valid=0; disp_ready=0; squash_valid=0; rob_free=8;
            tick; @(negedge clock); reset=0;
        end
    endtask
    task enqueue(input [31:0] pc, input [5:0] op, input [4:0] rs1, rs2, rd);
        begin
            @(negedge clock);
            if (!decode_ready) $fatal(1,"unexpected queue backpressure");
            decode_valid=1; decode_uop={pc,pc+32'd4,op,rs1,rs2,rd,32'd0};
            tick; @(negedge clock); decode_valid=0;
        end
    endtask
    reg [5:0] p0, p1, branch_dst;
    initial begin
        initialize;
        enqueue(0,11,0,0,5);
        enqueue(4,32,5,0,6);
        #1;
        p0=disp_alu[64+2*PW +: PW]; p1=disp_lsq[0 +: PW];
        if (!disp_valid || disp_count!=2 || decode_ready) $fatal(1,"pair/full queue");
        if (p0==0 || p1==0 || p0==p1 || disp_mem[32+PW +: PW]!=p0 || disp_src1_ready[1])
            $fatal(1,"RAW or distinct destination allocation");
        // A full queue can accept a replacement while dispatching both entries.
        disp_ready=1; decode_valid=1; decode_uop={32'd8,32'd12,6'd11,5'd6,5'd0,5'd7,32'd0};
        tick; disp_ready=0; decode_valid=0; #1;
        if (dut.queued_count!=1 || dut.rat[5]!=p0 || dut.rat[6]!=p1)
            $fatal(1,"simultaneous queue replacement or RAT update");

        initialize;
        enqueue(0,32,0,0,5);
        enqueue(4,11,5,0,5);
        #1; p0=disp_lsq[0 +: PW]; p1=disp_alu[64+2*PW +: PW];
        if (disp_count!=2 || disp_rob[19 -: PW]!=p0 || disp_alu[64+PW +: PW]!=p0 ||
            disp_src1_ready[0] || p0==p1) $fatal(1,"WAW old map and RAW bypass");
        disp_ready=1; tick; disp_ready=0;
        if (dut.rat[5]!=p1) $fatal(1,"youngest WAW must win");

        initialize;
        enqueue(0,32,0,0,8);
        enqueue(4,3,0,0,1);
        #1; p0=disp_lsq[0 +: PW]; branch_dst=disp_alu[64+2*PW +: PW];
        disp_ready=1; #1;
        if (!cp_alloc_valid || cp_alloc_payload[32 +: RW]!=1) $fatal(1,"branch checkpoint tag");
        tick; disp_ready=0;
        enqueue(8,11,0,0,8);
        enqueue(12,32,0,0,9);
        #1; p1=disp_alu[64+2*PW +: PW];
        disp_ready=1; tick; disp_ready=0;
        @(negedge clock); squash_valid=1; tick; squash_valid=0;
        if (dut.rat[8]!=p0 || dut.rat[1]!=branch_dst || !dut.free_q[p1] || dut.free_q[p0])
            $fatal(1,"checkpoint restores packet prefix and frees younger registers");

        initialize;
        enqueue(0,11,0,0,5);
        enqueue(4,11,0,0,6);
        #1;
        if (disp_count!=1) $fatal(1,"same queue must split into two packets");
        disp_ready=1; tick; disp_ready=0;
        if (dut.queued_count!=1 || disp_alu[64+2*PW +: PW]==0) $fatal(1,"prefix consumption");

        initialize;
        enqueue(0,32,0,0,8);
        enqueue(4,11,0,0,0);
        #1;
        if (disp_count!=2 || disp_alu[64+2*PW +: PW]!=0) $fatal(1,"x0 allocation");
        rob_free=1; #1;
        if (disp_count!=1) $fatal(1,"ROB single-slot fallback");

        initialize;
        @(negedge clock); decode_valid=1;
        decode_uop={32'd0,32'h100,6'd11,5'd0,5'd0,5'd5,32'd0};
        tick; @(negedge clock); decode_valid=0;
        enqueue(4,32,0,0,6);
        // Correction after lane 0 must discard the buffered lane 1.
        #1;
        if (disp_count!=1) $fatal(1,"frontend correction terminates packet");
        disp_ready=1; tick; disp_ready=0;
        if (!front_redirect_valid || front_redirect_pc!=4 || decode_ready)
            $fatal(1,"frontend correction handshake");
        tick;
        if (dut.queued_count!=0 || disp_valid || dut.rat[6]!=6)
            $fatal(1,"frontend correction must discard queued younger instructions");
        $display("PASS rename_dual: RAW WAW checkpoint queue prefix x0 resource fallback frontend correction");
        $finish;
    end
    initial begin #10000; $fatal(1,"timeout"); end
endmodule
