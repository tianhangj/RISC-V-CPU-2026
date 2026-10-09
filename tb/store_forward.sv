module store_forward_test #(parameter integer BUFFERED=0);
    reg clock=0; always #5 clock=~clock;
    reg st_start_valid=0, st_start_id=0, st_req_ready=0, st_rsp_valid=0;
    reg reset=1, squash_valid=0, exec_valid=0, result_ready=1;
    reg [2:0] rob_head=0, squash_tag=0;
    reg [1:0] disp_valid=0;
    reg [21:0] disp_lsq=0;
    reg [102:0] exec_payload=0;
    wire result_valid, ld_req_valid;
    wire [40:0] result_payload;
    lsu #(.BUFFER_STORES(BUFFERED), .STORE_FORWARD(1), .RESULT_PIPELINED(1), .DISPATCH_WIDTH(2),
        .ROB_DEPTH(8), .PRF_SIZE(36), .LQ_DEPTH(2), .SQ_DEPTH(2), .LOAD_OUTSTANDING(2)) dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head, .current_gen(16'd7),
        .disp_valid, .disp_lsq, .exec_valid, .exec_payload,
        .store_data_valid(1'b1), .store_psrc(6'd0),
        .forward_valid(3'd0), .forward_pdst(18'd0), .forward_value(96'd0),
        .result_valid, .result_ready, .result_payload, .st_start_valid, .st_start_id,
        .ld_req_valid, .ld_req_ready(1'b0), .ld_rsp_valid(1'b0), .ld_rsp_payload(49'd0),
        .st_req_ready, .st_rsp_valid);
    task automatic tick;
        @(posedge clock); #1; @(negedge clock);
    endtask
    task automatic restart;
        reset=1; st_start_valid=0; st_req_ready=0; st_rsp_valid=0; rob_head=0; disp_valid=0; exec_valid=0; result_ready=1; squash_valid=0;
        tick(); reset=0;
    endtask
    task automatic allocate(input bit store, input bit id, input [2:0] tag);
        disp_valid=1; disp_lsq={11'd0,store,id,tag,6'(store?0:32)}; tick(); disp_valid=0;
    endtask
    task automatic execute(input [2:0] op, input bit id, input [2:0] tag,
                           input [31:0] addr, data);
        exec_valid=1; exec_payload={tag,op,id,addr,32'd0,data}; tick(); exec_valid=0;
    endtask
    task automatic expect_load(input [31:0] value);
        integer waited;
        waited=0;
        while (!(result_valid && result_payload[37:32]==32)) begin
            if (ld_req_valid || waited>12) $fatal(1,"covered Load went to Cache or stalled");
            tick(); waited=waited+1;
        end
        if (result_payload[31:0]!==value) $fatal(1,"Store forwarding data/extension wrong: %h",result_payload);
        tick();
    endtask
    initial begin
        tick(); restart();
        allocate(1,0,0); allocate(1,1,1); allocate(0,0,2);
        execute(7,0,0,32'h40,32'h12345678);
        execute(7,1,1,32'h40,32'h89abcdef);
        execute(2,0,2,32'h40,0); expect_load(32'h89abcdef);
        restart();
        allocate(1,0,0); allocate(0,0,1);
        execute(5,0,0,32'h43,32'hffffff80);
        execute(0,0,1,32'h43,0); expect_load(32'hffffff80);
        restart();
        allocate(1,0,0); allocate(1,1,1); allocate(0,0,2);
        execute(7,0,0,32'h40,32'h12345678);
        execute(5,1,1,32'h41,32'hff);
        execute(2,0,2,32'h40,0);
        repeat (5) begin
            tick();
            if (ld_req_valid || (result_valid && result_payload[37:32]==32))
                $fatal(1,"partial younger Store incorrectly forwarded an older full word");
        end
        restart();
        allocate(1,0,0); allocate(0,0,1);
        execute(2,0,1,32'h40,0);
        repeat (3) begin tick(); if (ld_req_valid) $fatal(1,"Load passed an unknown Store address"); end
        execute(7,0,0,32'h40,32'h87654321); expect_load(32'h87654321);
        if (BUFFERED!=0) begin
            restart();
            allocate(1,0,0); allocate(1,1,1);
            execute(7,0,0,32'h40,32'h12345678);
            execute(7,1,1,32'h40,32'h89abcdef);
            st_start_valid=1; st_start_id=0; tick(); st_start_id=1; tick(); st_start_valid=0;
            // Other instructions can wrap the ROB while Cache stalls these
            // committed Stores. Their FIFO order must supersede recycled tags.
            rob_head=1; allocate(0,0,2);
            execute(2,0,2,32'h40,0); expect_load(32'h89abcdef);
            st_req_ready=1; tick(); st_req_ready=0;
            st_rsp_valid=1; tick(); st_rsp_valid=0;
            // Retire the first FIFO entry, then reuse its slot. The newer
            // ticket is numerically smaller after wrap but has greater rank.
            allocate(1,0,3); execute(7,0,3,32'h40,32'h5555aaaa);
            st_start_valid=1; st_start_id=0; tick(); st_start_valid=0;
            rob_head=2; allocate(0,0,4);
            execute(2,0,4,32'h40,0); expect_load(32'h5555aaaa);
        end
        $display("PASS Store forwarding: youngest overlap, signed byte, partial coverage and unknown address");
        $finish;
    end
    initial begin #5000; $fatal(1,"Store forwarding timeout"); end
endmodule
