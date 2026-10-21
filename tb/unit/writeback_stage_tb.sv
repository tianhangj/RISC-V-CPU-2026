`timescale 1ns/1ps
module writeback_stage_tb;
    reg clock=0;
    always #5 clock=~clock;
    reg reset=1, squash_valid=0, disp_fire=0;
    reg [2:0] squash_tag=0;
    reg [1:0] disp_count=2, sources=0;
    reg [17:0] disp_rob=0;
    reg [40:0] primary=0, secondary=0;
    wire [3:0] rob_free;
    wire [2:0] rob_head, rob_tail;
    wire [1:0] done_valid, write_valid, reg_commit_valid;
    wire [5:0] done_tag;
    wire [11:0] write_pdst, reg_commit_payload;
    wire [63:0] write_value, rd_data;
    wire alu_ready, alu2_ready;
    wb_arb #(.EXTRA_ALU(1),.ROB_DEPTH(8),.PRF_SIZE(40)) arb (
        .clock,.reset,.squash_valid,.squash_tag,.rob_head,
        .alu_result_valid(sources[0]),.alu_result_ready(alu_ready),.alu_result_payload(primary),
        .alu2_result_valid(sources[1]),.alu2_result_ready(alu2_ready),.alu2_result_payload(secondary),
        .mul_result_valid(1'b0),.mul_result_ready(),.mul_result_payload(41'b0),
        .lsu_result_valid(1'b0),.lsu_result_ready(),.lsu_result_payload(41'b0),
        .done_valid,.done_tag,.write_valid,.write_pdst,.write_value);
    rob #(.DISPATCH_WIDTH(2),.ROB_DEPTH(8),.PRF_SIZE(40),.SQ_DEPTH(2)) retirement (
        .clock,.reset,.squash_valid,.squash_tag,.disp_fire,.disp_count,.disp_rob,
        .done_valid,.done_tag,.rob_free,.rob_head,.rob_tail,
        .reg_commit_valid,.reg_commit_payload,.st_start_valid(),.st_start_id(),.st_done_valid(1'b0));
    prf #(.PRF_SIZE(40)) registers (
        .clock,.reset,.rd_addr({6'd34,6'd33}),.rd_data,.write_valid,.write_pdst,.write_value);
    task tick;
        begin @(posedge clock); #1; end
    endtask
    task allocate(input [5:0] old0, old1);
        begin
            @(negedge clock); disp_fire=1;
            disp_rob={{old1,2'd0,1'b0},{old0,2'd0,1'b0}};
            tick; @(negedge clock); disp_fire=0;
        end
    endtask
    initial begin
        tick; @(negedge clock); reset=0;
        allocate(5,6);
        sources=3; primary={3'd0,6'd33,32'd111}; secondary={3'd1,6'd34,32'd222};
        #1;
        if (done_valid!=0) $fatal(1,"MEM results crossed WB without a register");
        if (!alu_ready || !alu2_ready) $fatal(1,"two-wide WB acceptance");
        tick;
        if (done_valid!=3 || reg_commit_valid!=3 || reg_commit_payload!={6'd6,6'd5})
            $fatal(1,"WB and in-order retirement must share the edge");
        if (rd_data!={32'd222,32'd111}) $fatal(1,"WB-to-ID bypass missing before PRF write");
        @(negedge clock); sources=0;
        tick;
        if (rob_free!=8 || rd_data!={32'd222,32'd111})
            $fatal(1,"retirement or PRF persistence after WB");

        allocate(7,8);
        sources=3; primary={3'd2,6'd33,32'd777}; secondary={3'd3,6'd34,32'd999};
        tick;
        @(negedge clock); sources=0; squash_valid=1; squash_tag=2;
        #1;
        if (done_valid!=1 || write_valid!=1 || reg_commit_valid!=1)
            $fatal(1,"squash did not filter a younger registered WB lane");
        tick;
        @(negedge clock); squash_valid=0;
        #1;
        if (rob_free!=8 || rd_data!={32'd222,32'd777})
            $fatal(1,"squashed WB changed the register file or ROB");

        disp_count=1; allocate(0,0);
        sources=1; primary={3'd3,6'd0,32'hbad};
        tick;
        if (done_valid!=1 || write_valid!=0 || retirement.retire_count!=1)
            $fatal(1,"x0 result must retire without a PRF write");
        @(negedge clock); sources=0;
        tick;
        if (rob_free!=8) $fatal(1,"x0 retirement leaked a ROB entry");
        $display("PASS writeback_stage: MEM/WB register, dual retirement, bypass, squash, x0");
        $finish;
    end
    initial begin #2000; $fatal(1,"timeout"); end
endmodule
