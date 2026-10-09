module ordered_iq_test;
    reg clock=0; always #5 clock=~clock;
    reg reset=1, squash_valid=0, cand_take=0;
    reg [4:0] rob_head=30, squash_tag=2;
    reg [1:0] disp_valid=0, disp_src1_ready=0;
    reg [189:0] disp_uop=0;
    reg wake_valid=0;
    reg [5:0] wake_pdst=0;
    wire cand_valid;
    wire [94:0] cand_uop;
    wire [2:0] free_count;
    iq_core #(.ISSUE_WIDTH(1), .DISPATCH_WIDTH(2), .WB_WIDTH(1),
        .DEPTH(5), .ORDERED_SELECT(1), .BYPASS_WAKE(1)) dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .disp_valid, .disp_prepare(disp_valid), .disp_uop,
        .disp_src1_ready, .disp_src2_ready(2'b11), .wake_valid, .wake_pdst,
        .free_count, .cand_valid, .cand_src2_ready(), .cand_uop, .cand_take);
    function automatic [94:0] item(input [4:0] tag, input [5:0] src);
        item={tag,2'd0,6'd20,6'd32,src,6'd0,64'd0};
    endfunction
    task automatic tick;
        @(posedge clock); #1; @(negedge clock);
    endtask
    task automatic expect_tag(input [4:0] tag);
        #1;
        if (!cand_valid || cand_uop[94:90]!==tag)
            $fatal(1,"ordered IQ expected %0d, got %0d",tag,cand_uop[94:90]);
    endtask
    initial begin
        tick(); reset=0;
        disp_valid=3; disp_uop={item(31,6),item(30,4)}; tick();
        disp_uop={item(1,0),item(0,0)}; disp_src1_ready=3; tick(); disp_valid=0;
        expect_tag(0);
        wake_valid=1; wake_pdst=4; expect_tag(30);
        cand_take=1; tick(); cand_take=0; wake_valid=0; rob_head=31;
        expect_tag(0);
        // Reuse the oldest freed slot with a younger instruction.
        disp_valid=3; disp_uop={item(3,0),item(2,0)}; tick(); disp_valid=0;
        expect_tag(0); cand_take=1; tick(); cand_take=0;
        expect_tag(1);
        wake_valid=1; wake_pdst=6; expect_tag(31);
        cand_take=1; tick(); wake_valid=0; cand_take=0; rob_head=0;
        expect_tag(1); cand_take=1; tick(); cand_take=0;
        expect_tag(2);
        squash_valid=1; tick(); squash_valid=0;
        expect_tag(2); cand_take=1; tick(); cand_take=0;
        #1;
        if (cand_valid || free_count!=5) $fatal(1,"ordered IQ squash/release failed");
        $display("PASS ordered IQ: wake bypass, slot reuse, paired dispatch, ROB wrap and squash");
        $finish;
    end
endmodule
