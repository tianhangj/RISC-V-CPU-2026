module store_buffer_test #(parameter integer FAST=0);
    reg clock=0; always #5 clock=~clock;
    reg reset=1, squash_valid=0, disp_valid=0, exec_valid=0;
    reg [2:0] rob_head=0, squash_tag=0;
    reg [11:0] disp_lsq=0;
    reg [103:0] exec_payload=0;
    reg store_data_valid=0;
    reg [5:0] store_psrc=32;
    reg [2:0] forward_valid=0;
    reg [17:0] forward_pdst=0;
    reg [95:0] forward_value=0;
    reg st_start_valid=0, st_req_ready=0, st_rsp_valid=0;
    reg first_store_completed=0;
    always @(posedge clock)
        if (reset) first_store_completed<=0;
        else if (result_valid && result_payload[40:38]==0) first_store_completed<=1;
    reg [1:0] st_start_id=0;
    wire st_req_valid, st_done_valid, result_valid, ld_req_valid;
    wire [67:0] st_req_payload;
    wire [49:0] ld_req_payload;
    wire [40:0] result_payload;
    lsu #(.PIPELINED(0), .RESULT_PIPELINED(FAST!=1), .BYPASS_STORE_RESULTS(FAST==2), .BUFFER_STORES(1), .EARLY_STORE(1),
        .EARLY_STORE_COMMIT(FAST), .STORE_LOOKAHEAD(FAST), .REGISTER_STORE_RESULT(FAST),
        .DISPATCH_WIDTH(1), .ROB_DEPTH(8), .PRF_SIZE(36), .LQ_DEPTH(4), .SQ_DEPTH(4)) dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head, .current_gen(16'd0),
        .disp_valid, .disp_lsq, .exec_valid, .exec_payload, .store_data_valid, .store_psrc,
        .forward_valid, .forward_pdst, .forward_value,
        .result_valid, .result_ready(1'b1), .result_payload,
        .st_start_valid, .st_start_id, .st_done_valid, .st_req_valid, .st_req_ready,
        .st_req_payload, .st_rsp_valid, .ld_req_valid, .ld_req_ready(1'b0), .ld_req_payload,
        .ld_rsp_valid(1'b0), .ld_rsp_payload(50'd0));
    task automatic tick;
        @(posedge clock); #1; @(negedge clock);
    endtask
    task automatic allocate(input is_store, input [1:0] id, input [2:0] tag);
        disp_valid=1; disp_lsq={is_store,id,tag,6'd33};
        tick(); disp_valid=0;
    endtask
    task automatic address(input [1:0] id, input [2:0] tag, op,
        input [31:0] addr, data, input data_ready);
        exec_valid=1; store_data_valid=data_ready;
        exec_payload={tag,op,id,addr,32'd0,data};
        tick(); exec_valid=0;
    endtask
    task automatic authorize(input [1:0] id);
        st_start_valid=1; st_start_id=id;
        #1;
        if (FAST!=0 && dut.sq_addr[id][31:28]==0 && !st_done_valid)
            $fatal(1,"RAM authorization did not acknowledge on its acceptance edge");
        if (dut.sq_addr[id][31:28]!=0 && st_done_valid)
            $fatal(1,"MMIO acknowledged on authorization edge");
        tick(); st_start_valid=0;
    endtask
    task automatic check_write(input [31:0] addr, data);
        if (!st_req_valid || st_req_payload!=={addr,data,4'hf})
            $fatal(1,"committed Store order/data changed: %h",st_req_payload);
    endtask
    task automatic complete_write;
        st_req_ready=1; tick(); st_req_ready=0;
        st_rsp_valid=1; tick(); st_rsp_valid=0;
    endtask
    initial begin
        tick(); reset=0;
        allocate(1,0,0);
        address(0,0,7,32'h100,32'd0,0);
        if (result_valid) $fatal(1,"Store completed before its data was ready");
        allocate(0,0,1);
        address(0,1,2,32'h200,32'd0,1);
        #1;
        if (!ld_req_valid || ld_req_payload[31:0]!=32'h200)
            $fatal(1,"known nonoverlapping Store address blocked a Load");
        forward_valid=1; forward_pdst[5:0]=32; forward_value[31:0]=32'h12345678;
        tick(); forward_valid=0;
        tick();
        if (FAST!=0 ? !first_store_completed : (!result_valid || result_payload[40:38]!=0))
            $fatal(1,"late Store data did not complete its ROB entry");
        authorize(0);
        if (FAST==0 && !st_done_valid) $fatal(1,"RAM Store did not retire into committed queue");
        tick(); rob_head=1;
        squash_valid=1; squash_tag=1; tick(); squash_valid=0;
        check_write(32'h100,32'h12345678);
        if (!dut.sq_valid[0] || !dut.sq_committed[0])
            $fatal(1,"recovery discarded an older retired Store");
        allocate(1,1,2); address(1,2,7,32'h104,32'd7,1);
        tick(); authorize(1);
        if (FAST==0 && !st_done_valid) $fatal(1,"second committed Store acknowledgment missing");
        tick(); rob_head=3;
        repeat (2) begin check_write(32'h100,32'h12345678); tick(); end
        complete_write();
        if (st_done_valid) $fatal(1,"RAM Store physical response acknowledged ROB twice");
        check_write(32'h104,32'd7);
        allocate(1,2,3); address(2,3,7,32'h80000000,32'd42,1);
        tick(); authorize(2);
        if (st_done_valid) $fatal(1,"MMIO retired before its external response");
        complete_write(); check_write(32'h80000000,32'd42);
        st_req_ready=1; tick(); st_req_ready=0;
        if (st_done_valid) $fatal(1,"MMIO retired before B response");
        st_rsp_valid=1; #1;
        if (!st_done_valid) $fatal(1,"MMIO completion missing");
        tick(); st_rsp_valid=0;
        if (dut.commit_count!=0 || st_req_valid) $fatal(1,"Store queue did not drain");
        if (FAST!=0) begin
            allocate(1,0,4); address(0,4,7,32'h300,32'd11,1);
            tick(); authorize(0);
            allocate(1,1,5); address(1,5,7,32'h304,32'd12,1);
            tick(); authorize(1);
            check_write(32'h300,32'd11);
            st_req_ready=1; tick(); st_req_ready=0;
            st_rsp_valid=1; st_req_ready=1; #1;
            check_write(32'h304,32'd12);
            if (st_done_valid) $fatal(1,"physical RAM completion acknowledged ROB twice");
            tick(); st_rsp_valid=0; st_req_ready=0;
            if (dut.sq_valid[0] || !dut.sq_valid[1] || dut.commit_count!=1 || st_req_valid)
                $fatal(1,"lookahead lost the next accepted write or released the wrong slot");
            st_rsp_valid=1; tick(); st_rsp_valid=0;
            if (dut.commit_count!=0 || dut.sq_valid!=0 || st_req_valid)
                $fatal(1,"lookahead writes did not drain");
        end
        $display("PASS early Store address, late data, committed FIFO, recovery and MMIO");
        $finish;
    end
endmodule
