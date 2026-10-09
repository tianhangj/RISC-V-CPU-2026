module data_prefetch_test;
    reg clock=0; always #5 clock=~clock;
    reg reset=1, dc_req_valid=0, mem_rsp_valid=0, write_fire=0, line_req_valid=0;
    reg [49:0] dc_req_payload=0;
    reg [51:0] mem_rsp_payload=0;
    wire dc_req_ready, dc_rsp_valid, mem_req_valid, line_req_ready, line_rsp_valid;
    wire [49:0] dc_rsp_payload;
    wire [51:0] mem_req_payload;
    wire [127:0] line_rsp_data;
    reg [51:0] captured [0:31];
    integer count=0;
    data_prefetch #(.LINE_BYTES(16)) dut (
        .clock, .reset, .dc_req_valid, .dc_req_ready, .dc_req_payload,
        .dc_rsp_valid, .dc_rsp_payload, .mem_req_valid, .mem_req_ready(1'b1),
        .mem_req_payload, .mem_rsp_valid, .mem_rsp_payload, .write_fire,
        .line_req_valid, .line_req_ready, .line_rsp_valid, .line_rsp_data);
    always @(posedge clock)
        if (!reset && mem_req_valid) begin
            if (count>=32) $fatal(1,"unexpected prefetch request count");
            captured[count]=mem_req_payload; count=count+1;
        end
    task automatic tick;
        @(posedge clock); #1; @(negedge clock);
    endtask
    task automatic response(input [51:0] identity, input [31:0] data);
        mem_rsp_valid=1; mem_rsp_payload={identity[51:32],data};
        tick(); mem_rsp_valid=0;
    endtask
    initial begin
        tick(); reset=0;
        dc_req_valid=1; dc_req_payload={16'd1,2'd0,32'd0};
        tick(); dc_req_valid=0;
        while (count<5) tick();
        if (captured[0][35:34]!=0) $fatal(1,"demand read lost its source ID");
        response(captured[0],32'h01234567);
        // Fill a prefetch out of word order, with distinct values per word.
        response(captured[3],32'ha0000018);
        response(captured[1],32'ha0000010);
        response(captured[4],32'ha000001c);
        response(captured[2],32'ha0000014);
        dc_req_payload={16'd2,2'd0,32'd16}; line_req_valid=1;
        #1;
        if (!line_req_ready) $fatal(1,"completed line was not offered for bulk refill");
        tick(); line_req_valid=0;
        if (!line_rsp_valid || line_rsp_data!==128'ha000001ca0000018a0000014a0000010)
            $fatal(1,"bulk prefetch snapshot lost word ordering");
        tick();
        dc_req_payload={16'd3,2'd2,32'd24}; dc_req_valid=1;
        #1;
        if (!dc_req_ready) $fatal(1,"buffered word was not ready");
        tick(); dc_req_valid=0;
        if (!dc_rsp_valid || dc_rsp_payload!=={16'd3,2'd2,32'ha0000018})
            $fatal(1,"prefetch hit identity/data incorrect");
        // External demand responses have priority; retain a SRAM hit across
        // that conflict even though the unenabled SRAM output becomes X.
        mem_rsp_valid=1; mem_rsp_payload={16'hbeef,2'd0,2'd1,32'h55};
        #1;
        if (dc_rsp_payload!=={16'hbeef,2'd1,32'h55}) $fatal(1,"external response priority failed");
        tick(); mem_rsp_valid=0; #1;
        if (!dc_rsp_valid || dc_rsp_payload!=={16'd3,2'd2,32'ha0000018})
            $fatal(1,"SRAM response was lost during arbitration backpressure: valid=%b data=%h pending=%b held=%b held_data=%h",dc_rsp_valid,dc_rsp_payload,dut.buffer_pending,dut.buffer_held,dut.held_data);
        tick();
        while (count<9) tick();
        write_fire=1; tick(); write_fire=0;
        for (integer i=5; i<9; i=i+1) response(captured[i],32'hbad00000+32'(i));
        dc_req_payload={16'd4,2'd0,32'd32}; dc_req_valid=1;
        #1;
        if (line_req_ready || !mem_req_valid || mem_req_payload[35:34]!=0)
            $fatal(1,"writeback resurrected a stale in-flight prefetch");
        tick(); dc_req_valid=0;
        $display("PASS prefetch bulk/word data, arbitration and writeback invalidation");
        $finish;
    end
    initial begin #5000; $fatal(1,"prefetch test timed out"); end
endmodule
