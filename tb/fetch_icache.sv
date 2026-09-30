module fetch_icache_case #(
    parameter integer D = 2,
    parameter integer OUTSTANDING = 8
) (output logic done);
    localparam integer DCW = $clog2(D+1);
    localparam integer REQ_BITS = 16+4+DCW+32;
    localparam integer RSP_BITS = 16+4+DCW+D*32;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, redirect = 0, fetch_ready = 1;
    logic [47:0] redirect_payload = 0;
    wire ic_req_valid, ic_req_ready, ic_rsp_valid;
    wire [REQ_BITS-1:0] ic_req_payload;
    wire [RSP_BITS-1:0] ic_rsp_payload;
    wire fetch_valid;
    wire [DCW-1:0] fetch_count;
    wire [D*96-1:0] fetch_packet;
    wire if_req_valid, if_rsp_valid;
    wire [50:0] if_req_payload, if_rsp_payload;
    integer cycles = 0, qhead = 0, qtail = 0, qcount = 0;
    logic [50:0] queue [0:31];
    integer due [0:31];
    wire if_req_ready = qcount < 16 && cycles % 7 != 2;
    assign if_rsp_valid = qcount != 0 && cycles >= due[qhead];
    assign if_rsp_payload = {queue[qhead][50:32], word_at(queue[qhead][31:0])};
    integer received = 0, expected_pc = 28, phase = 0;
    integer run_length = 0, max_run = 0, credits = 0;
    logic out_stalled = 0, req_stalled = 0;
    logic [D*96+DCW-1:0] saved_output;
    logic [REQ_BITS-1:0] saved_req;
    function automatic [31:0] word_at(input [31:0] addr);
        word_at = addr ^ 32'hbadc0013;
    endfunction
    fetch #(.DISPATCH_WIDTH(D), .RESET_PC(28), .IFETCH_OUTSTANDING(OUTSTANDING)) frontend (
        .clock, .reset, .fetch_redirect_valid(redirect), .fetch_redirect_payload(redirect_payload),
        .ic_req_valid, .ic_req_ready, .ic_req_payload, .ic_rsp_valid, .ic_rsp_payload,
        .fetch_valid, .fetch_ready, .fetch_count, .fetch_packet);
    icache #(.DISPATCH_WIDTH(D), .ICACHE_SIZE_BYTES(1024)) cache (
        .clock, .reset, .fetch_redirect_valid(redirect),
        .ic_req_valid, .ic_req_ready, .ic_req_payload, .ic_rsp_valid, .ic_rsp_payload,
        .if_req_valid, .if_req_ready, .if_req_payload, .if_rsp_valid, .if_rsp_payload);
    always @(posedge clock) begin
        if (!reset) begin
            cycles <= cycles+1;
            if (cycles > 5000) $fatal(1, "fetch/cache timeout");
            if (if_req_valid && if_req_ready) begin
                queue[qtail] <= if_req_payload;
                due[qtail] <= cycles+6;
                qtail <= (qtail+1)%32;
            end
            if (if_rsp_valid) qhead <= (qhead+1)%32;
            qcount <= qcount+int'(if_req_valid && if_req_ready)-int'(if_rsp_valid);
            if (redirect) begin
                credits = 0;
                expected_pc = int'(redirect_payload[47:16]);
                received = 0;
                run_length = 0;
                out_stalled <= 0;
                req_stalled <= 0;
            end else begin
                if (out_stalled && (!fetch_valid || {fetch_count, fetch_packet} !== saved_output))
                    $fatal(1, "fetch output changed under backpressure");
                if (req_stalled && (!ic_req_valid || ic_req_payload !== saved_req))
                    $fatal(1, "fetch request changed under backpressure");
                out_stalled <= fetch_valid && !fetch_ready;
                req_stalled <= ic_req_valid && !ic_req_ready;
                saved_output <= {fetch_count, fetch_packet};
                saved_req <= ic_req_payload;
                if (ic_req_valid && ic_req_ready) begin
                    if (ic_req_payload[32 +: DCW] == 0 ||
                        int'(ic_req_payload[32 +: DCW])+int'(ic_req_payload[4:2]) > 8)
                        $fatal(1, "fetch request crossed cache line");
                    credits = credits+int'(ic_req_payload[32 +: DCW]);
                end
                if (ic_rsp_valid) credits = credits-int'(ic_rsp_payload[D*32 +: DCW]);
                if (credits < 0 || credits > OUTSTANDING) $fatal(1, "word credit accounting error");
                if (fetch_valid && fetch_ready) begin
                    if (fetch_count == 0 || fetch_count > D) $fatal(1, "invalid output count");
                    for (int lane = 0; lane < D; lane = lane+1)
                        if (lane < fetch_count) begin
                            if (fetch_packet[lane*96+64 +: 32] !== 32'(expected_pc) ||
                                fetch_packet[lane*96+32 +: 32] !==
                                    ((32'(expected_pc) >> 28) != 0 ? 32'b0 : word_at(32'(expected_pc))) ||
                                fetch_packet[lane*96 +: 32] !== 32'(expected_pc+4))
                                $fatal(1, "fetch packet corrupt or out of order D=%0d pc=%0d", D, expected_pc);
                            expected_pc = expected_pc+4;
                            received = received+1;
                        end
                end
                if (phase == 1 && fetch_ready) begin
                    if (fetch_valid && fetch_count == D) run_length = run_length+1;
                    else run_length = 0;
                    if (run_length > max_run) max_run = run_length;
                end
            end
        end
    end
    task automatic jump(input [31:0] target, input [15:0] gen);
        @(negedge clock);
        redirect = 1;
        redirect_payload = {target, gen};
        @(negedge clock) redirect = 0;
    endtask
    initial begin
        done = 0;
        repeat (3) @(negedge clock);
        reset = 0;
        // Warm several lines, crossing line boundaries and repeatedly wrapping FQ.
        wait (received >= 64);
        @(negedge clock) fetch_ready = 0;
        repeat (6) @(negedge clock);
        // Measure steady hits after the warm-up's physical refill has drained.
        while (cache.fill_busy || ic_req_valid) @(negedge clock);
        jump(32'd32, 16'd1);
        phase = 1;
        fetch_ready = 1;
        wait (received >= 40);
        @(negedge clock);
        if (OUTSTANDING >= D && max_run < 8)
            $fatal(1, "sustained fetch width missing D=%0d max_run=%0d", D, max_run);
        fetch_ready = 0;
        repeat (8) @(negedge clock);
        fetch_ready = 1;
        wait (received >= 56);
        // RAM boundary and 32-bit wrap: out-of-RAM instructions must be local NOPs.
        @(negedge clock) phase = 2;
        jump(32'hfffffffc, 16'd2);
        wait (fetch_valid);
        @(negedge clock);
        if (fetch_packet[95:64] !== 32'hfffffffc || fetch_packet[63:32] !== 0 || fetch_packet[31:0] !== 0)
            $fatal(1, "non-RAM PC wrap did not produce NOP");
        $display("PASS fetch/icache D=%0d outstanding=%0d max_run=%0d", D, OUTSTANDING, max_run);
        done = 1;
    end
endmodule
module fetch_icache_test;
    wire [3:0] done;
    fetch_icache_case #(.D(1)) c0(done[0]);
    fetch_icache_case #(.D(2)) c1(done[1]);
    fetch_icache_case #(.D(4)) c2(done[2]);
    fetch_icache_case #(.D(4), .OUTSTANDING(1)) c3(done[3]);
    initial begin
        wait (&done);
        $display("PASS all fetch/cache configurations");
        $finish;
    end
endmodule
