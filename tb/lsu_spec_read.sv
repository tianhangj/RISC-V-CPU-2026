module lsu_spec_read_test;
    reg clock=0; always #5 clock=~clock;
    reg reset=1, squash_valid=0, disp_valid=0, exec_valid=0, read_exec_valid=0;
    reg [2:0] squash_tag=0;
    reg [15:0] current_gen=7;
    reg [10:0] disp_lsq=0;
    reg [102:0] exec_payload=0;
    reg ld_req_ready=1, ld_rsp_valid=0;
    reg [48:0] ld_rsp_payload=0;
    wire ld_req_valid, result_valid;
    wire [48:0] ld_req_payload;
    wire [40:0] result_payload;
    lsu #(.SPEC_READ_PREVIEW(1), .PIPELINED(0), .RESULT_PIPELINED(1),
        .EARLY_LOAD(1), .RESPONSE_FIRST(1), .DISPATCH_WIDTH(1),
        .ROB_DEPTH(8), .PRF_SIZE(36), .LQ_DEPTH(2), .SQ_DEPTH(2), .LOAD_OUTSTANDING(2)) dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head(3'd0), .current_gen,
        .disp_valid, .disp_lsq, .exec_valid, .read_exec_valid, .exec_payload,
        .store_data_valid(1'b1), .store_psrc(6'd0),
        .forward_valid(3'd0), .forward_pdst(18'd0), .forward_value(96'd0),
        .result_valid, .result_ready(1'b1), .result_payload,
        .st_start_valid(1'b0), .st_start_id(1'b0), .st_req_ready(1'b0), .st_rsp_valid(1'b0),
        .ld_req_valid, .ld_req_ready, .ld_req_payload, .ld_rsp_valid, .ld_rsp_payload);
    task automatic tick;
        @(posedge clock); #1; @(negedge clock);
    endtask
    task automatic allocate(input [2:0] tag, input [5:0] pdst);
        disp_valid=1; disp_lsq={1'b0,1'b0,tag,pdst}; tick(); disp_valid=0;
    endtask
    initial begin
        tick(); reset=0;
        allocate(1,32);
        // The actual young execution is cancelled, but its RAM read may be
        // accepted on the recovery edge with the original identity.
        squash_valid=1; read_exec_valid=1;
        exec_payload={3'd1,3'd2,1'b0,32'h200,32'd0,32'd0}; #1;
        if (!ld_req_valid || ld_req_payload!=={16'd7,1'b0,32'h200})
            $fatal(1,"recovery preview lost its original RAM request");
        tick(); squash_valid=0; read_exec_valid=0;
        if (dut.lq_valid[0] || dut.outstanding_q!=1)
            $fatal(1,"cancelled read did not free its slot and retain its credit");
        current_gen=8; allocate(2,33);
        exec_valid=1; read_exec_valid=1;
        exec_payload={3'd2,3'd2,1'b0,32'h204,32'd0,32'd0}; tick();
        exec_valid=0; read_exec_valid=0;
        ld_rsp_valid=1; ld_rsp_payload={16'd7,1'b0,32'hdeadbeef}; tick(); ld_rsp_valid=0;
        if (result_valid || !dut.lq_valid[0] || dut.lq_state[0]!=2 || dut.outstanding_q!=1)
            $fatal(1,"old response corrupted a reused Load slot");
        ld_rsp_valid=1; ld_rsp_payload={16'd8,1'b0,32'h12345678}; tick(); ld_rsp_valid=0;
        if (!result_valid || result_payload!=={3'd2,6'd33,32'h12345678})
            $fatal(1,"new generation did not complete the reused Load");
        tick();
        if (dut.outstanding_q!=0 || dut.lq_valid[0]) $fatal(1,"read credits or slot did not drain");

        // A stalled, cancelled preview must not retain an offer whose AGU
        // address was never written into the invalidated LQ slot.
        allocate(3,32); ld_req_ready=0; read_exec_valid=1; squash_valid=1;
        exec_payload={3'd3,3'd2,1'b0,32'h300,32'd0,32'd0}; tick();
        read_exec_valid=0; squash_valid=0;
        if (ld_req_valid || dut.offer_valid || dut.lq_valid[0])
            $fatal(1,"stalled cancelled preview escaped on a later cycle");
        $display("PASS speculative RAM preview: recovery acceptance, generation reuse and stalled cancellation");
        $finish;
    end
    initial begin #3000; $fatal(1,"speculative read test timeout"); end
endmodule
