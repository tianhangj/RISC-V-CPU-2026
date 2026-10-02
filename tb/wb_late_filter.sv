module wb_late_filter_test;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, squash_valid = 1;
    logic [1:0] alu_result_valid = 0;
    logic mul_result_valid = 0, lsu_result_valid = 0;
    wire [1:0] alu_result_ready, done_valid, write_valid;
    wire mul_result_ready, lsu_result_ready;
    wire [9:0] done_tag;
    wire [11:0] write_pdst;
    wire [63:0] write_value;
    wb_arb #(.FILTER_AFTER_SELECT(1)) dut (
        .clock, .reset, .squash_valid, .squash_tag(5'd31), .rob_head(5'd30),
        .alu_result_valid, .alu_result_ready,
        .alu_result_payload({5'd31, 6'd34, 32'h11111111, 5'd1, 6'd33, 32'hbadbad00}),
        .mul_result_valid, .mul_result_ready,
        .mul_result_payload({5'd0, 6'd35, 32'hbadbad01}),
        .lsu_result_valid, .lsu_result_ready,
        .lsu_result_payload({5'd30, 6'd36, 32'h22222222}),
        .done_valid, .done_tag, .write_valid, .write_pdst, .write_value);
    initial begin
        @(posedge clock);
        @(negedge clock);
        reset = 0;
        alu_result_valid = 2'b11;
        mul_result_valid = 1;
        lsu_result_valid = 1;
        #1;
        if (alu_result_ready != 2'b11 || mul_result_ready || lsu_result_ready ||
            done_valid != 2'b10 || write_valid != 2'b10 ||
            done_tag[5 +: 5] != 31 || write_pdst[6 +: 6] != 34 ||
            write_value[32 +: 32] != 32'h11111111)
            $fatal(1, "late filter lost the older ALU result or published younger data");
        @(posedge clock);
        #1;
        alu_result_valid = 0;
        #1;
        if (alu_result_ready != 0 || !mul_result_ready || !lsu_result_ready ||
            done_valid != 2'b10 || write_valid != 2'b10 ||
            done_tag[5 +: 5] != 30 || write_pdst[6 +: 6] != 36)
            $fatal(1, "late filter lost the older LSU result or failed cursor wrap");
        // Arbitration readiness is independent of the recovery boundary.
        squash_valid = 0;
        #1;
        if (!mul_result_ready || !lsu_result_ready || done_valid != 2'b11 || write_valid != 2'b11)
            $fatal(1, "recovery changed source selection");
        $display("late writeback recovery filtering PASS");
        $finish;
    end
endmodule
