module direct_rename_test;
    reg clock=0; always #5 clock=~clock;
    reg reset=1, squash_valid=0, decode_valid=0;
    reg [3:0] cp_release_mask=0;
    reg [116:0] decode_uop=0;
    reg [4:0] rob_tail=0;
    reg disp_ready=1;
    wire decode_ready, disp_valid, cp_alloc_valid, front_redirect_valid;
    wire [94:0] disp_alu;
    wire [31:0] front_redirect_pc;
    single_rename #(.DIRECT_RENAME(1), .CHECKPOINT_RAM(1), .DISPATCH_WIDTH(1),
        .WB_WIDTH(1), .COMMIT_WIDTH(1), .PRF_SIZE(48)) dut (
        .clock, .reset, .squash_valid, .restore_cp_id(2'd0), .cp_release_mask,
        .cp_free(3'd4), .cp_alloc_id(2'd0), .decode_valid, .decode_ready,
        .decode_count(1'b1), .decode_uop, .rob_free(6'd32), .rob_tail,
        .alu_iq_free(5'd8), .mem_iq_free(5'd8), .lq_free(4'd8), .sq_free(4'd8),
        .lq_alloc_id(3'd0), .sq_alloc_id(3'd0), .disp_valid, .disp_ready, .disp_alu,
        .cp_alloc_valid, .front_redirect_valid, .front_redirect_pc,
        .wake_valid(1'b0), .wake_pdst(6'd0), .reg_commit_valid(1'b0), .reg_commit_payload(6'd0));
    always @(posedge clock) if (!reset && disp_valid && disp_ready) rob_tail<=rob_tail+1'b1;
    task automatic tick;
        @(posedge clock); #1; @(negedge clock);
    endtask
    task automatic instruction(input [31:0] pc,npc, input [5:0] op,
        input [4:0] rs1,rs2,rd);
        decode_valid=1; decode_uop={pc,npc,op,rs1,rs2,rd,32'd4}; #1;
    endtask
    task automatic sources(input [5:0] ps1,ps2,pdst);
        if (!decode_ready || !disp_valid || disp_alu[75:64]!=={ps1,ps2} || disp_alu[81:76]!==pdst)
            $fatal(1,"direct Rename projection incorrect: %h",disp_alu);
    endtask
    initial begin
        tick(); reset=0;
        instruction(0,4,11,0,0,1); sources(0,0,32);
        disp_ready=0; #1;
        if (decode_ready) $fatal(1,"direct Rename accepted a backpressured instruction");
        tick(); disp_ready=1; #1; sources(0,0,32); tick();
        instruction(4,8,3,0,0,2); sources(0,0,33);
        if (!cp_alloc_valid) $fatal(1,"branch checkpoint was not allocated atomically");
        tick();
        instruction(8,12,11,1,0,1); sources(32,0,34); tick();
        instruction(12,16,20,1,2,3); sources(34,33,35); tick();
        decode_valid=0; squash_valid=1; cp_release_mask=1;
        tick(); squash_valid=0; cp_release_mask=0;
        if (decode_ready) $fatal(1,"Rename accepted during synchronous checkpoint restoration");
        tick();
        instruction(16,20,20,1,2,4); sources(32,33,34); tick();
        instruction(20,32'h12345678,11,0,0,5); tick(); decode_valid=0;
        if (!front_redirect_valid || front_redirect_pc!=24)
            $fatal(1,"registered frontend correction missing");
        tick();
        if (front_redirect_valid) $fatal(1,"frontend correction repeated");
        $display("PASS direct Rename, SRAM checkpoint, branch destination and free-list recovery");
        $finish;
    end
endmodule
