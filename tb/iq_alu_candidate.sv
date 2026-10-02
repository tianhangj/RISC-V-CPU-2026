module iq_alu_candidate_test;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic squash_valid = 0;
    logic [4:0] squash_tag = 0;
    logic [4:0] rob_head = 0;
    logic [1:0] disp_valid = 0;
    logic [189:0] disp_uop = 0;
    logic [1:0] disp_src1_ready = 2'b11;
    logic [1:0] disp_src2_ready = 2'b11;
    logic [1:0] wake_valid = 0;
    logic [11:0] wake_pdst = 0;
    logic [1:0] cand_take = 0;
    wire [2:0] alu_iq_free;
    wire [1:0] cand_valid;
    wire [189:0] cand_uop;

    iq_alu #(.IQ_ALU_DEPTH(4)) dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .disp_valid, .disp_prepare(disp_valid), .disp_uop, .disp_src1_ready, .disp_src2_ready,
        .wake_valid, .wake_pdst, .alu_iq_free,
        .cand_valid, .cand_uop, .cand_take
    );

    function automatic [94:0] item(input [4:0] tag, input [5:0] ps1);
        item = {tag, 2'b0, 6'd20, 6'd1, ps1, 6'd0, 32'd0, 32'd0};
    endfunction

    task automatic tick;
        @(posedge clock);
        #1;
    endtask

    task automatic expect_candidates(input [1:0] valid,
                                     input [4:0] tag0, tag1);
        if (cand_valid !== valid) $fatal(1, "candidate valid %b, expected %b", cand_valid, valid);
        if (valid[0] && cand_uop[94:90] !== tag0)
            $fatal(1, "lane 0 tag %d, expected %d", cand_uop[94:90], tag0);
        if (valid[1] && cand_uop[189:185] !== tag1)
            $fatal(1, "lane 1 tag %d, expected %d", cand_uop[189:185], tag1);
    endtask

    initial begin
        tick();
        if (alu_iq_free !== 3'd4) $fatal(1, "reset did not empty IQ");
        expect_candidates(2'b00, 0, 0);

        @(negedge clock);
        reset = 0;
        disp_valid = 2'b11;
        disp_uop = {item(5'd5, 0), item(5'd3, 0)};
        tick();
        if (alu_iq_free !== 3'd2) $fatal(1, "dispatch occupancy mismatch");
        expect_candidates(2'b00, 0, 0);

        @(negedge clock);
        disp_valid = 0;
        tick();
        if (alu_iq_free !== 3'd4) $fatal(1, "IQ entries not released at transfer edge");
        expect_candidates(2'b11, 5'd3, 5'd5);

        @(negedge clock);
        disp_valid = 2'b11;
        disp_uop = {item(5'd4, 0), item(5'd2, 0)};
        tick();
        if (alu_iq_free !== 3'd2) $fatal(1, "full candidate stage lost IQ capacity");
        expect_candidates(2'b11, 5'd3, 5'd5);

        @(negedge clock);
        disp_valid = 0;
        cand_take = 2'b01;
        tick();
        if (alu_iq_free !== 3'd3) $fatal(1, "consumed candidate did not refill");
        expect_candidates(2'b11, 5'd2, 5'd5);

        @(negedge clock);
        cand_take = 0;
        disp_valid = 2'b01;
        disp_uop[94:0] = item(5'd1, 0);
        tick();
        if (alu_iq_free !== 3'd2) $fatal(1, "older IQ item not dispatched");
        expect_candidates(2'b11, 5'd2, 5'd5);

        @(negedge clock);
        disp_valid = 0;
        squash_tag = 5'd3;
        squash_valid = 1;
        #1;
        expect_candidates(2'b01, 5'd2, 0);
        tick();
        if (alu_iq_free !== 3'd4) $fatal(1, "squash and transfer did not free IQ");
        expect_candidates(2'b11, 5'd1, 5'd2);

        @(negedge clock);
        squash_valid = 0;
        cand_take = 2'b11;
        tick();
        expect_candidates(2'b00, 0, 0);

        @(negedge clock);
        cand_take = 0;
        disp_valid = 2'b01;
        disp_uop[94:0] = item(5'd6, 6'd7);
        disp_src1_ready[0] = 0;
        tick();
        expect_candidates(2'b00, 0, 0);

        @(negedge clock);
        disp_valid = 0;
        wake_valid[0] = 1;
        wake_pdst[5:0] = 6'd7;
        #1;
        expect_candidates(2'b00, 0, 0);
        tick();
        expect_candidates(2'b01, 5'd6, 0);
        if (alu_iq_free !== 3'd4) $fatal(1, "wake did not transfer at the writeback edge");
        @(negedge clock);
        wake_valid = 0;
        tick();
        expect_candidates(2'b01, 5'd6, 0);
        if (alu_iq_free !== 3'd4) $fatal(1, "wake candidate was duplicated");

        $display("iq_alu candidate stage PASS");
        $finish;
    end
endmodule
