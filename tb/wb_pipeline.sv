module wb_pipeline_test;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, squash_valid = 0;
    logic [4:0] squash_tag = 31, rob_head = 30;
    logic alu_result_valid = 0;
    logic [42:0] alu_result_payload = 0;
    wire alu_result_ready, mul_result_ready, lsu_result_ready;
    wire done_valid, write_valid;
    wire [4:0] done_tag;
    wire [5:0] write_pdst;
    wire [31:0] write_value;
    wb_arb #(.PIPELINED(1), .ISSUE_WIDTH(1), .WB_WIDTH(1)) dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .alu_result_valid, .alu_result_ready, .alu_result_payload,
        .mul_result_valid(1'b0), .mul_result_ready, .mul_result_payload(43'b0),
        .lsu_result_valid(1'b0), .lsu_result_ready, .lsu_result_payload(43'b0),
        .done_valid, .done_tag, .write_valid, .write_pdst, .write_value
    );
    task automatic tick;
        @(posedge clock);
        #1;
    endtask
    task automatic expect_write(input [4:0] tag, input [5:0] pdst, input [31:0] value);
        if (!done_valid || done_tag != tag || write_valid != (pdst != 0) ||
            write_pdst != pdst || write_value != value)
            $fatal(1, "pipelined writeback mismatch");
    endtask
    initial begin
        tick();
        if (done_valid || write_valid) $fatal(1, "reset published a result");
        @(negedge clock);
        reset = 0;
        alu_result_valid = 1;
        alu_result_payload = {5'd31, 6'd33, 32'h12345678};
        #1;
        if (!alu_result_ready || done_valid) $fatal(1, "writeback bypassed its register");
        tick();
        expect_write(31, 33, 32'h12345678);
        @(negedge clock);
        squash_valid = 1;
        #1;
        expect_write(31, 33, 32'h12345678);
        // Incoming younger data is discarded on the same boundary.
        alu_result_payload = {5'd1, 6'd34, 32'hdeadbeef};
        #1;
        if (!alu_result_ready) $fatal(1, "younger input was not discarded");
        tick();
        if (done_valid || write_valid) $fatal(1, "younger input reached writeback");
        @(negedge clock);
        squash_valid = 0;
        alu_result_payload = {5'd1, 6'd34, 32'hdeadbeef};
        tick();
        expect_write(1, 34, 32'hdeadbeef);
        // Squash must also filter data already held in the pipeline.
        @(negedge clock);
        alu_result_valid = 0;
        squash_valid = 1;
        #1;
        if (done_valid || write_valid) $fatal(1, "buffered younger result survived squash");
        tick();
        @(negedge clock);
        squash_valid = 0;
        alu_result_valid = 1;
        alu_result_payload = {5'd31, 6'd0, 32'd7};
        tick();
        expect_write(31, 0, 7);
        @(negedge clock);
        alu_result_payload = {5'd0, 6'd35, 32'd8};
        tick();
        expect_write(0, 35, 8);
        @(negedge clock);
        reset = 1;
        tick();
        if (done_valid || write_valid) $fatal(1, "reset retained buffered result");
        $display("pipelined writeback PASS");
        $finish;
    end
endmodule
