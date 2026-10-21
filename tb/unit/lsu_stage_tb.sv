`timescale 1ns/1ps
module lsu_stage_tb;
    reg clock=0;
    always #5 clock=~clock;
    reg reset=1, squash_valid=0, disp_valid=0, exec_valid=0;
    reg [2:0] squash_tag=0;
    reg [3:0] current_gen=0;
    reg [10:0] disp_lsq=0;
    reg [102:0] exec_payload=0;
    reg result_ready=1, ld_req_ready=0, ld_rsp_valid=0;
    reg [36:0] ld_rsp_payload=0;
    wire result_valid, ld_req_valid;
    wire [40:0] result_payload;
    wire [36:0] ld_req_payload;
    reg [36:0] held_request;
    lsu #(.ROB_DEPTH(8),.PRF_SIZE(40),.LQ_DEPTH(2),.SQ_DEPTH(2),
          .LOAD_OUTSTANDING(4),.GEN_WIDTH(4)) dut (
        .clock,.reset,.squash_valid,.squash_tag,.rob_head(3'd0),.current_gen,
        .disp_valid,.disp_lsq,.lq_has_free(),.sq_has_free(),.lq_alloc_id(),.sq_alloc_id(),
        .store_data_valid(1'b1),.store_psrc(6'd0),
        .forward_valid(3'b0),.forward_pdst(18'b0),.forward_value(96'b0),
        .exec_valid,.addr_valid(exec_valid),.exec_ready(),.exec_payload,.result_valid,.result_ready,.result_payload,
        .st_start_valid(1'b0),.st_start_id(1'b0),.st_done_valid(),
        .ld_req_valid,.ld_req_ready,.ld_req_payload,.ld_rsp_valid,.ld_rsp_payload,
        .st_req_valid(),.st_req_ready(1'b1),.st_req_payload(),.st_rsp_valid(1'b0));
    task tick;
        begin @(posedge clock); #1; end
    endtask
    task allocate(input store, input id, input [2:0] tag);
        begin
            @(negedge clock); disp_valid=1; disp_lsq={store,id,tag,6'd35};
            tick; @(negedge clock); disp_valid=0;
        end
    endtask
    initial begin
        tick; @(negedge clock); reset=0;
        allocate(0,0,0);
        exec_valid=1; exec_payload={3'd0,3'd2,1'b0,32'h100,32'd0,32'd0};
        #1;
        if (!ld_req_valid || ld_req_payload!={4'd0,1'b0,32'h100})
            $fatal(1,"EX Load must request MEM without an address-wait cycle");
        held_request=ld_req_payload;
        tick;
        @(negedge clock); exec_valid=0; exec_payload=0;
        #1;
        if (!ld_req_valid || ld_req_payload!=held_request)
            $fatal(1,"AGU request changed under cache backpressure");
        ld_req_ready=1; tick;
        @(negedge clock); ld_req_ready=0; ld_rsp_valid=1;
        ld_rsp_payload={4'd0,1'b0,32'h12345678};
        #1;
        if (!result_valid || result_payload!={3'd0,6'd35,32'h12345678})
            $fatal(1,"direct Load lost response identity or data");
        tick; @(negedge clock); ld_rsp_valid=0;

        allocate(1,0,1);
        exec_valid=1; exec_payload={3'd1,3'd7,1'b0,32'h100,32'd0,32'haabbccdd};
        tick; @(negedge clock); exec_valid=0; tick;
        allocate(0,0,2);
        exec_valid=1; exec_payload={3'd2,3'd2,1'b0,32'h100,32'd0,32'd0};
        #1;
        if (ld_req_valid || !dut.load_forward_valid[0])
            $fatal(1,"current AGU Load did not forward the older Store");
        tick; @(negedge clock); exec_valid=0; result_ready=0;
        #1;
        if (!result_valid || result_payload!={3'd2,6'd35,32'haabbccdd})
            $fatal(1,"AGU capture overwrote forwarded Load state");
        tick; tick;
        if (!result_valid || result_payload[31:0]!=32'haabbccdd)
            $fatal(1,"Load completion changed under WB backpressure");
        @(negedge clock); result_ready=1; tick;

        allocate(1,1,3);
        allocate(0,0,4);
        exec_valid=1; exec_payload={3'd4,3'd2,1'b0,32'h104,32'd0,32'd0};
        #1;
        if (ld_req_valid || dut.load_forward_valid[0])
            $fatal(1,"AGU bypass crossed an older unknown-address Store");
        tick;
        @(negedge clock); exec_payload={3'd3,3'd7,1'b1,32'h104,32'd0,32'hcafebabe};
        tick; @(negedge clock); exec_valid=0; tick;
        if (!result_valid || result_payload!={3'd4,6'd35,32'hcafebabe})
            $fatal(1,"blocked Load did not resume after Store address resolution");
        tick;

        allocate(0,0,5);
        exec_valid=1; exec_payload={3'd5,3'd2,1'b0,32'h108,32'd0,32'd0};
        squash_valid=1; squash_tag=4; ld_req_ready=1;
        #1;
        if (!ld_req_valid) $fatal(1,"recovery entered the speculative address path");
        tick; @(negedge clock); exec_valid=0; squash_valid=0;
        current_gen=1;
        allocate(0,0,6);
        exec_valid=1; exec_payload={3'd6,3'd2,1'b0,32'h10c,32'd0,32'd0};
        #1;
        if (!ld_req_valid || ld_req_payload[36:33]!=1)
            $fatal(1,"reused LQ slot did not take the new generation");
        tick; @(negedge clock); exec_valid=0; ld_req_ready=0;
        ld_rsp_valid=1; ld_rsp_payload={4'd0,1'b0,32'hdeadbeef};
        #1;
        if (result_valid) $fatal(1,"canceled response completed a reused LQ slot");
        tick; @(negedge clock); ld_rsp_payload={4'd1,1'b0,32'hfeedface};
        #1;
        if (!result_valid || result_payload!={3'd6,6'd35,32'hfeedface})
            $fatal(1,"new-generation response was lost after canceled response");
        tick; @(negedge clock); ld_rsp_valid=0;
        if (dut.outstanding_q!=0) $fatal(1,"canceled read leaked a memory credit");
        $display("PASS lsu_stage: AGU/MEM merge, request hold, Store forwarding, hazards, squash");
        $finish;
    end
    initial begin #3000; $fatal(1,"timeout"); end
endmodule
