module iq_mem_candidate_test;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic squash_valid = 0;
    logic [4:0] squash_tag = 0;
    logic [4:0] rob_head = 0;
    logic [1:0] disp_valid = 0;
    logic [109:0] disp_uop = 0;
    logic [1:0] disp_src1_ready = 2'b11;
    logic [1:0] disp_src2_ready = 2'b11;
    logic [1:0] wake_valid = 0;
    logic [11:0] wake_pdst = 0;
    logic cand_take = 0;
    wire [4:0] mem_iq_free;
    wire cand_valid;
    wire [54:0] cand_uop;

    iq_mem dut (.*);

    function automatic [54:0] item(input [4:0] tag, input [5:0] ps1);
        item = {tag, 3'd0, 3'd0, ps1, 6'd0, 32'd0};
    endfunction

    task automatic tick;
        @(posedge clock);
        #1;
    endtask

    task automatic expect_candidate(input logic valid, input [4:0] tag);
        if (cand_valid !== valid)
            $fatal(1, "candidate valid %b, expected %b", cand_valid, valid);
        if (valid && cand_uop[54:50] !== tag)
            $fatal(1, "candidate tag %d, expected %d", cand_uop[54:50], tag);
    endtask

    initial begin
        tick();
        if (mem_iq_free !== 5'd16) $fatal(1, "reset capacity mismatch");
        expect_candidate(0, 0);

        @(negedge clock);
        reset = 0;
        rob_head = 5'd30;
        disp_valid = 2'b11;
        disp_uop = {item(5'd0, 6'd7), item(5'd31, 0)};
        disp_src1_ready = 2'b01;
        tick();
        if (mem_iq_free !== 5'd14) $fatal(1, "dispatch capacity mismatch");
        expect_candidate(0, 0);

        @(negedge clock);
        disp_valid = 0;
        wake_valid[0] = 1;
        wake_pdst[5:0] = 6'd7;
        #1;
        expect_candidate(0, 0);
        tick();
        if (mem_iq_free !== 5'd15) $fatal(1, "candidate transfer did not free IQ slot");
        expect_candidate(1, 5'd31);

        @(negedge clock);
        wake_valid = 0;
        disp_valid = 2'b11;
        disp_uop = {item(5'd2, 0), item(5'd1, 0)};
        tick();
        if (mem_iq_free !== 5'd13) $fatal(1, "backpressure lost IQ capacity");
        expect_candidate(1, 5'd31);

        @(negedge clock);
        disp_valid = 0;
        cand_take = 1;
        tick();
        if (mem_iq_free !== 5'd14) $fatal(1, "take did not refill candidate");
        expect_candidate(1, 5'd0);

        @(negedge clock);
        tick();
        if (mem_iq_free !== 5'd15) $fatal(1, "second refill did not free IQ slot");
        expect_candidate(1, 5'd1);

        @(negedge clock);
        cand_take = 0;
        squash_valid = 1;
        squash_tag = 5'd1;
        #1;
        expect_candidate(1, 5'd1);
        tick();
        if (mem_iq_free !== 5'd16) $fatal(1, "squash did not free younger IQ entry");
        expect_candidate(1, 5'd1);

        @(negedge clock);
        squash_valid = 0;
        cand_take = 1;
        tick();
        if (mem_iq_free !== 5'd16) $fatal(1, "final capacity mismatch");
        expect_candidate(0, 0);

        @(negedge clock);
        cand_take = 0;
        disp_valid = 2'b01;
        disp_uop[54:0] = item(5'd4, 0);
        tick();
        expect_candidate(0, 0);

        @(negedge clock);
        disp_valid = 0;
        tick();
        expect_candidate(1, 5'd4);

        @(negedge clock);
        disp_valid = 2'b01;
        disp_uop[54:0] = item(5'd2, 0);
        tick();
        if (mem_iq_free !== 5'd15) $fatal(1, "new IQ entry missing");
        expect_candidate(1, 5'd4);

        @(negedge clock);
        disp_valid = 0;
        squash_valid = 1;
        squash_tag = 5'd3;
        #1;
        expect_candidate(0, 0);
        tick();
        if (mem_iq_free !== 5'd16) $fatal(1, "surviving refill did not free IQ slot");
        expect_candidate(1, 5'd2);

        @(negedge clock);
        squash_valid = 0;
        cand_take = 1;
        tick();
        expect_candidate(0, 0);

        $display("iq_mem single candidate PASS");
        $finish;
    end
endmodule
