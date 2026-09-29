module fetch_generation;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic redirect = 0;
    logic [47:0] redirect_payload = 0;
    wire if_req_valid;
    wire [49:0] if_req_payload;
    logic if_rsp_valid = 0;
    logic [49:0] if_rsp_payload = 0;
    wire fetch_valid;
    wire [0:0] fetch_count;
    wire [95:0] fetch_packet;
    fetch #(.DISPATCH_WIDTH(1), .FETCH_QUEUE_DEPTH(4), .IFETCH_OUTSTANDING(2)) dut (
        .clock, .reset,
        .fetch_redirect_valid(redirect), .fetch_redirect_payload(redirect_payload),
        .if_req_valid, .if_req_ready(1'b1), .if_req_payload,
        .if_rsp_valid, .if_rsp_payload,
        .fetch_valid, .fetch_ready(1'b0), .fetch_count, .fetch_packet
    );
    initial begin
        repeat (3) @(posedge clock);
        @(negedge clock) reset = 0;
        wait (if_req_valid && if_req_payload[31:0] == 0);
        @(posedge clock);
        @(negedge clock);
        redirect = 1;
        redirect_payload = {32'h00000100, 16'd1};
        @(posedge clock);
        @(negedge clock) redirect = 0;
        wait (if_req_valid && if_req_payload[31:0] == 32'h00000100);
        @(posedge clock);
        @(negedge clock);
        if_rsp_valid = 1;
        if_rsp_payload = {16'd0, 2'd0, 32'hdeadbeef};
        @(posedge clock);
        @(negedge clock);
        if_rsp_valid = 0;
        if (fetch_valid) $fatal(1, "stale response became visible");
        if_rsp_valid = 1;
        if_rsp_payload = {16'd1, 2'd0, 32'h12345678};
        @(posedge clock);
        @(negedge clock) if_rsp_valid = 0;
        repeat (3) @(posedge clock);
        if (!fetch_valid || fetch_packet[95:64] !== 32'h00000100 ||
            fetch_packet[63:32] !== 32'h12345678)
            $fatal(1, "new generation response missing");
        $display("PASS fetch generation filtering");
        $finish;
    end
endmodule
