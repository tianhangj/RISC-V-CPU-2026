module lsu_pipeline_test #(parameter integer P = 1);
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, squash_valid = 0, disp_valid = 0, exec_valid = 0;
    logic [2:0] squash_tag = 0;
    logic [11:0] disp_lsq = 0;
    logic [103:0] exec_payload = 0;
    logic result_ready = 0, ld_rsp_valid = 0;
    logic [49:0] ld_rsp_payload = 0;
    wire [1:0] lq_alloc_id;
    wire ld_req_valid, result_valid;
    wire [49:0] ld_req_payload;
    wire [40:0] result_payload;
    logic [1:0] first_id, second_id, third_id;
    lsu #(.PIPELINED(P), .DISPATCH_WIDTH(1), .ROB_DEPTH(8), .PRF_SIZE(36),
        .LQ_DEPTH(4), .SQ_DEPTH(2), .LOAD_OUTSTANDING(4)) dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head(3'd0), .current_gen(16'd0),
        .disp_valid, .disp_lsq, .lq_alloc_id, .exec_valid, .exec_payload,
        .result_valid, .result_ready, .result_payload,
        .st_start_valid(1'b0), .st_start_id(1'b0),
        .ld_req_valid, .ld_req_ready(1'b1), .ld_req_payload,
        .ld_rsp_valid, .ld_rsp_payload,
        .st_req_ready(1'b1), .st_rsp_valid(1'b0)
    );

    task automatic tick;
        @(posedge clock);
        #1;
    endtask
    task automatic load(input [2:0] tag, input [5:0] pdst,
                        input [2:0] op, input [31:0] addr, output [1:0] id);
        @(negedge clock);
        id = lq_alloc_id;
        disp_valid = 1;
        disp_lsq = {1'b0, id, tag, pdst};
        tick();
        @(negedge clock);
        disp_valid = 0;
        exec_valid = 1;
        exec_payload = {tag, op, id, addr, 32'b0, 32'b0};
        #1;
        if (P == 0 && (!ld_req_valid ||
            ld_req_payload !== {16'd0, id, (addr & 32'hfffffffc)}))
            $fatal(1, "direct AGU-to-cache request inserted a bubble");
        tick();
        if (P == 1 && (!ld_req_valid || ld_req_payload !== {16'd0, id, (addr & 32'hfffffffc)}))
            $fatal(1, "AGU-to-request preparation inserted a bubble");
        if (P == 0 && ld_req_valid) $fatal(1, "direct Load request duplicated");
        @(negedge clock) exec_valid = 0;
        tick();
    endtask
    task automatic respond(input [1:0] id, input [31:0] data);
        @(negedge clock);
        ld_rsp_valid = 1;
        ld_rsp_payload = {16'd0, id, data};
        tick();
        @(negedge clock) ld_rsp_valid = 0;
    endtask
    task automatic expect_result(input [2:0] tag, input [5:0] pdst, input [31:0] value);
        if (!result_valid || result_payload !== {tag, pdst, value})
            $fatal(1, "LSU lost or delayed response tag=%0d value=%h", tag, value);
    endtask

    initial begin
        tick();
        @(negedge clock) reset = 0;
        load(1, 32, 0, 3, first_id);  // signed byte at offset 3
        load(2, 33, 4, 6, second_id); // unsigned halfword at offset 2
        load(3, 34, 2, 8, third_id);
        respond(first_id, 32'h80000000);
        expect_result(1, 32, 32'hffffff80);
        // A second response must be buffered while the first output is stalled.
        respond(second_id, 32'habcd1234);
        repeat (3) begin
            expect_result(1, 32, 32'hffffff80);
            tick();
        end
        @(negedge clock) result_ready = 1;
        tick();
        expect_result(2, 33, 32'h0000abcd);
        // Consume the old result and forward another response at the same edge.
        respond(third_id, 32'h12345678);
        expect_result(3, 34, 32'h12345678);
        tick();
        if (result_valid) $fatal(1, "LSU duplicated a forwarded response");

        load(4, 35, 2, 12, first_id);
        @(negedge clock);
        ld_rsp_valid = 1;
        ld_rsp_payload = {16'd0, first_id, 32'h13579bdf};
        #1;
        if (P == 0) expect_result(4, 35, 32'h13579bdf);
        tick();
        @(negedge clock) ld_rsp_valid = 0;
        if (P == 1) begin
            expect_result(4, 35, 32'h13579bdf);
            tick();
        end
        if (result_valid) $fatal(1, "direct Load response duplicated");

        // A squash-edge response must not survive even when WB cannot accept it.
        @(negedge clock) result_ready = 0;
        load(5, 35, 2, 16, first_id);
        @(negedge clock);
        squash_valid = 1;
        squash_tag = 4;
        ld_rsp_valid = 1;
        ld_rsp_payload = {16'd0, first_id, 32'hdeadbeef};
        tick();
        if (result_valid) $fatal(1, "squash-edge response escaped age filtering");
        $display("PASS LSU P=%0d AGU/response forwarding, extension, WB stalls and squash", P);
        $finish;
    end
    initial begin
        #2000;
        $fatal(1, "LSU pipeline timeout");
    end
endmodule
