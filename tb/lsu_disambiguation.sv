module lsu_disambiguation;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic [1:0] disp_valid = 0;
    logic [21:0] disp_lsq = 0;
    logic exec_valid = 0;
    logic [102:0] exec_payload = 0;
    wire ld_req_valid;
    wire [48:0] ld_req_payload;
    lsu #(.DISPATCH_WIDTH(2), .ROB_DEPTH(8), .PRF_SIZE(36),
        .LQ_DEPTH(2), .SQ_DEPTH(2), .LOAD_OUTSTANDING(2)) dut (
        .clock, .reset, .squash_valid(1'b0), .squash_tag(3'b0),
        .rob_head(3'b0), .current_gen(16'b0), .disp_valid, .disp_lsq,
        .lq_free(), .sq_free(), .lq_alloc_id(), .sq_alloc_id(),
        .exec_valid, .exec_ready(), .exec_payload,
        .result_valid(), .result_ready(1'b1), .result_payload(),
        .st_start_valid(1'b0), .st_start_id(1'b0), .st_done_valid(),
        .ld_req_valid, .ld_req_ready(1'b0), .ld_req_payload,
        .ld_rsp_valid(1'b0), .ld_rsp_payload(49'b0),
        .st_req_valid(), .st_req_ready(1'b0), .st_req_payload(),
        .st_rsp_valid(1'b0)
    );
    initial begin
        repeat (3) @(posedge clock);
        @(negedge clock) reset = 0;
        disp_valid = 2'b11;
        disp_lsq[10:0] = {1'b1, 1'b0, 3'd0, 6'd0};
        disp_lsq[21:11] = {1'b0, 1'b0, 3'd1, 6'd32};
        @(posedge clock);
        @(negedge clock);
        disp_valid = 0;
        exec_valid = 1;
        exec_payload = {3'd1, 3'd2, 1'b0, 32'h20, 32'b0, 32'b0};
        @(posedge clock);
        @(negedge clock) exec_valid = 0;
        repeat (3) @(posedge clock);
        if (ld_req_valid) $fatal(1, "load bypassed unknown older store");
        @(negedge clock);
        exec_valid = 1;
        exec_payload = {3'd0, 3'd7, 1'b0, 32'h40, 32'b0, 32'habcdef01};
        @(posedge clock);
        @(negedge clock) exec_valid = 0;
        repeat (2) @(posedge clock);
        if (!ld_req_valid || ld_req_payload[31:0] !== 32'h20)
            $fatal(1, "nonoverlapping load remained blocked");
        $display("PASS LSU store disambiguation");
        $finish;
    end
endmodule
