module store_pipeline_test;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, squash_valid = 0, disp_valid = 0, exec_valid = 0;
    logic [2:0] squash_tag = 0;
    logic [10:0] disp_lsq = 0;
    logic [102:0] exec_payload = 0;
    logic [8:0] disp_rob = 0;
    logic st_req_ready = 0, st_rsp_valid = 0, result_ready = 1;
    wire result_valid, st_start_valid, st_req_valid, st_done_valid;
    wire [40:0] result_payload;
    wire [67:0] st_req_payload;
    wire st_start_id, sq_alloc_id;
    wire [2:0] rob_head, rob_tail;
    wire [3:0] rob_free;
    wire [1:0] sq_free;
    rob #(.DISPATCH_WIDTH(1), .WB_WIDTH(1), .COMMIT_WIDTH(1),
          .ROB_DEPTH(8), .PRF_SIZE(36), .SQ_DEPTH(2)) u_rob (
        .clock, .reset, .squash_valid, .squash_tag,
        .disp_fire(disp_valid), .disp_count(1'b1), .disp_rob,
        .done_valid(result_valid && result_ready), .done_tag(result_payload[40:38]),
        .rob_free, .rob_tail, .rob_head, .st_start_valid, .st_start_id, .st_done_valid
    );
    lsu #(.PIPELINED(0), .DISPATCH_WIDTH(1), .ROB_DEPTH(8), .PRF_SIZE(36),
          .LQ_DEPTH(2), .SQ_DEPTH(2), .LOAD_OUTSTANDING(2)) u_lsu (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head, .current_gen(16'd0),
        .disp_valid, .disp_lsq, .sq_alloc_id, .sq_free,
        .exec_valid, .exec_payload, .result_valid, .result_ready, .result_payload,
        .st_start_valid, .st_start_id, .st_done_valid,
        .ld_req_ready(1'b1), .ld_rsp_valid(1'b0), .ld_rsp_payload(49'd0),
        .st_req_valid, .st_req_ready, .st_req_payload, .st_rsp_valid
    );
    task automatic tick;
        @(posedge clock);
        #1;
    endtask
    task automatic store(input [31:0] addr, input [31:0] data, input [2:0] op);
        @(negedge clock);
        disp_lsq = {1'b1, sq_alloc_id, rob_tail, 6'd0};
        disp_rob = {6'd0, 2'd3, sq_alloc_id};
        // ROB payload is prepared before publishing the dispatch event.
        tick();
        @(negedge clock) disp_valid = 1;
        tick();
        @(negedge clock);
        disp_valid = 0;
        exec_valid = 1;
        exec_payload = {rob_head, op, st_start_id, addr, 32'd0, data};
        #1;
    endtask
    task automatic expect_write(input [31:0] addr, input [31:0] data, input [3:0] strb);
        if (!st_req_valid || st_req_payload !== {addr, data, strb})
            $fatal(1, "Store authorization/request bubble or wrong data: %h", st_req_payload);
    endtask
    initial begin
        tick();
        @(negedge clock) reset = 0;
        store(32'h23, 32'h000000ab, 5); // byte, offset three
        if (!result_valid || !st_start_valid) $fatal(1, "head Store AGU completion delayed");
        expect_write(32'h20, 32'hab000000, 4'b1000);
        tick();
        @(negedge clock) exec_valid = 0;
        // Backpressure and younger recovery must retain the authorized offer.
        repeat (3) begin
            expect_write(32'h20, 32'hab000000, 4'b1000);
            tick();
        end
        @(negedge clock);
        squash_valid = 1;
        squash_tag = rob_head;
        st_req_ready = 1;
        expect_write(32'h20, 32'hab000000, 4'b1000);
        tick();
        @(negedge clock) squash_valid = 0;
        if (st_req_valid || st_start_valid) $fatal(1, "Store request/authorization duplicated");
        @(negedge clock) st_rsp_valid = 1;
        #1;
        if (!st_done_valid) $fatal(1, "Store response lost");
        tick();
        @(negedge clock) st_rsp_valid = 0;
        if (rob_head != 1 || sq_free != 2) $fatal(1, "Store failed to retire or release SQ");

        // A following Store must not inherit write_sent from its predecessor.
        result_ready = 0;
        store(32'h42, 32'h0000cdef, 6);
        if (st_start_valid || st_req_valid) $fatal(1, "Store wrote before ROB received completion");
        tick();
        @(negedge clock) exec_valid = 0;
        repeat (2) begin
            if (st_start_valid || st_req_valid) $fatal(1, "Store bypassed WB backpressure");
            tick();
        end
        @(negedge clock) result_ready = 1;
        #1;
        expect_write(32'h40, 32'hcdef0000, 4'b1100);
        tick();
        @(negedge clock);
        if (st_req_valid) $fatal(1, "accepted Store request repeated");
        @(negedge clock) st_rsp_valid = 1;
        tick();
        if (rob_head != 2 || sq_free != 2) $fatal(1, "following Store failed to retire");
        $display("PASS Store AGU/ROB/request bypass, backpressure, recovery and retirement");
        $finish;
    end
    initial begin
        #2000;
        $fatal(1, "Store pipeline timeout");
    end
endmodule
