module lsu_generation;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic squash_valid = 0;
    logic [2:0] squash_tag = 0;
    logic [15:0] current_gen = 0;
    logic disp_valid = 0;
    logic [10:0] disp_lsq = 0;
    logic exec_valid = 0;
    logic [102:0] exec_payload = 0;
    logic ld_rsp_valid = 0;
    logic [48:0] ld_rsp_payload = 0;
    logic result_ready = 0;
    wire ld_req_valid, result_valid;
    wire [48:0] ld_req_payload;
    wire [40:0] result_payload;
    lsu #(.DISPATCH_WIDTH(1), .ROB_DEPTH(8), .PRF_SIZE(36),
        .LQ_DEPTH(2), .SQ_DEPTH(2), .LOAD_OUTSTANDING(2)) dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head(3'd0), .current_gen,
        .disp_valid, .disp_lsq, .lq_free(), .sq_free(), .lq_alloc_id(), .sq_alloc_id(),
        .exec_valid, .exec_ready(), .exec_payload,
        .result_valid, .result_ready, .result_payload,
        .st_start_valid(1'b0), .st_start_id(1'b0), .st_done_valid(),
        .ld_req_valid, .ld_req_ready(1'b1), .ld_req_payload,
        .ld_rsp_valid, .ld_rsp_payload,
        .st_req_valid(), .st_req_ready(1'b1), .st_req_payload(), .st_rsp_valid(1'b0)
    );
    task automatic allocate_load(input [5:0] pdst);
        begin
            @(negedge clock);
            disp_valid = 1;
            disp_lsq = {1'b0, 1'b0, 3'd1, pdst};
            @(posedge clock);
            @(negedge clock);
            disp_valid = 0;
            exec_valid = 1;
            exec_payload = {3'd1, 3'd2, 1'b0, 32'd0, 32'd0, 32'd0};
            @(posedge clock);
            @(negedge clock) exec_valid = 0;
        end
    endtask
    initial begin
        repeat (3) @(posedge clock);
        @(negedge clock) reset = 0;
        allocate_load(6'd32);
        wait (ld_req_valid);
        if (ld_req_payload[48:33] !== 16'd0) $fatal(1, "old request generation");
        @(posedge clock);
        @(negedge clock);
        squash_valid = 1;
        @(posedge clock);
        @(negedge clock);
        squash_valid = 0;
        current_gen = 1;
        allocate_load(6'd33);
        wait (ld_req_valid);
        if (ld_req_payload[48:33] !== 16'd1) $fatal(1, "new request generation");
        @(posedge clock);
        @(negedge clock);
        ld_rsp_valid = 1;
        ld_rsp_payload = {16'd0, 1'b0, 32'hdeadbeef};
        @(posedge clock);
        @(negedge clock);
        ld_rsp_valid = 0;
        if (result_valid) $fatal(1, "stale load response produced a result");
        ld_rsp_valid = 1;
        ld_rsp_payload = {16'd1, 1'b0, 32'h12345678};
        @(posedge clock);
        @(negedge clock) ld_rsp_valid = 0;
        repeat (2) @(posedge clock);
        if (!result_valid || result_payload !== {3'd1, 6'd33, 32'h12345678})
            $fatal(1, "new load response missing: %h", result_payload);
        $display("PASS LSU generation filtering");
        $finish;
    end
    initial begin
        #1000;
        $fatal(1, "LSU generation test timeout");
    end
endmodule
