// End-to-end cache tests use the real bridge and a delayed, stalled AXI slave.
module icache_case #(
    parameter integer D = 2,
    parameter integer WAYS = 2,
    parameter integer LINE = 32,
    parameter integer SETS = 4
) (output logic done);
    localparam integer DCW = $clog2(D+1);
    localparam integer IW = $clog2(LINE/4);
    localparam integer REQ_BITS = 16+4+DCW+32;
    localparam integer RSP_BITS = 16+4+DCW+D*32;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, redirect = 0;
    logic ic_req_valid = 0;
    wire ic_req_ready, ic_rsp_valid;
    logic [REQ_BITS-1:0] ic_req_payload = 0;
    wire [RSP_BITS-1:0] ic_rsp_payload;
    wire if_req_valid, if_req_ready, if_rsp_valid;
    wire [16+IW+32-1:0] if_req_payload, if_rsp_payload;
    wire ld_req_valid, ld_req_ready, ld_rsp_valid;
    wire [50:0] ld_req_payload, ld_rsp_payload;
    wire [31:0] araddr, awaddr, wdata;
    wire arvalid, arready, rready, awvalid, wvalid, bready;
    wire [3:0] wstrb;
    logic loads = 0, release_reads = 1;
    logic [2:0] load_id = 0;
    integer load_pending = 0;
    integer cycles = 0, ar_count = 0, responses = 0, load_responses = 0;
    integer qhead = 0, qtail = 0, qcount = 0;
    logic [31:0] addresses [0:31];
    integer due [0:31];
    wire rvalid = qcount != 0 && cycles >= due[qhead] && release_reads;
    wire [31:0] rdata = word_at(addresses[qhead]);
    logic [15:0] gen = 0;
    integer next_id = 0;
    logic [15:0] expected_valid = 0;
    logic [31:0] expected_addr [0:15];
    logic [DCW-1:0] expected_count [0:15];
    logic [15:0] expected_gen [0:15];
    wire [3:0] rsp_id = ic_rsp_payload[D*32+DCW +: 4];
    wire [DCW-1:0] rsp_count = ic_rsp_payload[D*32 +: DCW];
    wire [15:0] rsp_gen = ic_rsp_payload[D*32+DCW+4 +: 16];
    integer reads_before, rsp_before, missing_id;
    logic ar_stalled = 0, fill_stalled = 0;
    logic [31:0] saved_ar;
    logic [16+IW+32-1:0] saved_fill;

    function automatic [31:0] word_at(input [31:0] addr);
        word_at = addr ^ 32'ha5000013;
    endfunction

    icache #(.DISPATCH_WIDTH(D), .ICACHE_WAYS(WAYS), .ICACHE_LINE_BYTES(LINE),
        .ICACHE_SIZE_BYTES(SETS*WAYS*LINE)) dut (
        .clock, .reset, .fetch_redirect_valid(redirect),
        .ic_req_valid, .ic_req_ready, .ic_req_payload, .ic_rsp_valid, .ic_rsp_payload,
        .if_req_valid, .if_req_ready, .if_req_payload, .if_rsp_valid, .if_rsp_payload);
    axi_bridge #(.AXI_RD_OUTSTANDING(4), .IF_ID_WIDTH(IW)) bridge (
        .clock, .reset, .if_req_valid, .if_req_ready, .if_req_payload, .if_rsp_valid, .if_rsp_payload,
        .ld_req_valid, .ld_req_ready, .ld_req_payload, .ld_rsp_valid, .ld_rsp_payload,
        .st_req_valid(1'b0), .st_req_ready(), .st_req_payload(68'b0), .st_rsp_valid(),
        .araddr, .arvalid, .arready, .rdata, .rresp(2'b0), .rvalid, .rready,
        .awaddr, .awvalid, .awready(1'b1), .wdata, .wstrb, .wvalid, .wready(1'b1),
        .bresp(2'b0), .bvalid(1'b0), .bready);
    assign arready = qcount < 16 && cycles % 5 != 1;
    assign ld_req_valid = loads && load_pending < 2;
    assign ld_req_payload = {16'hbabe, load_id, 32'h000f0000+(32'(load_id)<<2)};

    always @(posedge clock) begin
        if (!reset) begin
            cycles <= cycles + 1;
            if (cycles > 5000) $fatal(1, "cache test timeout D=%0d WAYS=%0d LINE=%0d", D, WAYS, LINE);
            if (ar_stalled && (!arvalid || araddr !== saved_ar)) $fatal(1, "AR changed under backpressure");
            if (fill_stalled && (!if_req_valid || if_req_payload !== saved_fill))
                $fatal(1, "refill offer changed under backpressure or redirect");
            ar_stalled <= arvalid && !arready;
            saved_ar <= araddr;
            fill_stalled <= if_req_valid && !if_req_ready;
            saved_fill <= if_req_payload;
            if (arvalid && arready) begin
                if (araddr[1:0] != 0 || araddr[31:28] != 0) $fatal(1, "illegal AR");
                addresses[qtail] <= araddr;
                due[qtail] <= cycles + 7 + (cycles % 3);
                qtail <= (qtail+1)%32;
                if (araddr < 32'h000f0000) ar_count <= ar_count+1;
            end
            if (rvalid && rready) qhead <= (qhead+1)%32;
            qcount <= qcount + int'(arvalid && arready) - int'(rvalid && rready);
            load_pending <= load_pending + int'(ld_req_valid && ld_req_ready) - int'(ld_rsp_valid);
            if (ld_req_valid && ld_req_ready) load_id <= load_id+1'b1;
            if (ld_rsp_valid) begin
                if (ld_rsp_payload[50:35] !== 16'hbabe ||
                    ld_rsp_payload[31:0] !== word_at(32'h000f0000+(32'(ld_rsp_payload[34:32])<<2)))
                    $fatal(1, "LD identity/data corrupted by IF refill");
                load_responses <= load_responses+1;
            end
            if (redirect) begin
                if (ic_rsp_valid || ic_req_ready) $fatal(1, "frontend event on redirect");
                expected_valid = 0;
            end else begin
                if (ic_rsp_valid) begin
                    if (!expected_valid[rsp_id] || expected_gen[rsp_id] !== rsp_gen ||
                        expected_count[rsp_id] !== rsp_count) $fatal(1, "unexpected cache response");
                    for (int lane = 0; lane < D; lane = lane+1)
                        if (lane < rsp_count && ic_rsp_payload[lane*32 +: 32] !== word_at(expected_addr[rsp_id]+32'(lane*4)))
                            $fatal(1, "cache word mismatch lane=%0d D=%0d", lane, D);
                    expected_valid[rsp_id] = 0;
                    responses <= responses+1;
                end
                if (ic_req_valid && ic_req_ready) begin
                    if (expected_valid[ic_req_payload[32+DCW +: 4]]) $fatal(1, "test reused active id");
                    expected_valid[ic_req_payload[32+DCW +: 4]] = 1;
                    expected_addr[ic_req_payload[32+DCW +: 4]] = ic_req_payload[31:0];
                    expected_count[ic_req_payload[32+DCW +: 4]] = ic_req_payload[32 +: DCW];
                    expected_gen[ic_req_payload[32+DCW +: 4]] = ic_req_payload[32+DCW+4 +: 16];
                end
            end
        end
    end

    task automatic send(input [31:0] addr, input integer count);
        @(negedge clock);
        ic_req_valid = 1;
        ic_req_payload = {gen, 4'(next_id), DCW'(count), addr};
        next_id = (next_id+1)%16;
        do @(posedge clock); while (!ic_req_ready);
        @(negedge clock) ic_req_valid = 0;
    endtask
    task automatic fetch_word(input [31:0] addr, input integer count);
        integer before_rsp;
        before_rsp = responses;
        send(addr, count);
        while (responses == before_rsp) @(negedge clock);
    endtask
    task automatic redirect_now;
        @(negedge clock);
        ic_req_valid = 0;
        redirect = 1;
        gen = gen+1'b1;
        next_id = 0; // Exercise immediate identity reuse across generations.
        @(negedge clock) redirect = 0;
    endtask

    initial begin
        done = 0;
        repeat (3) @(negedge clock);
        reset = 0;
        loads = 1;
        fetch_word(0, D);
        if (ar_count != LINE/4) $fatal(1, "cold line did not use one read per word");
        reads_before = ar_count;
        // Consecutive hit packets must return every cycle, including nonzero offsets.
        for (int packet = 0; packet < 10; packet = packet+1) begin
            @(negedge clock);
            ic_req_valid = 1;
            ic_req_payload = {gen, 4'(next_id), DCW'(D), 32'((packet % (LINE/(4*D)))*D*4)};
            next_id = (next_id+1)%16;
            @(posedge clock);
            if (!ic_req_ready || (packet != 0 && !ic_rsp_valid)) $fatal(1, "hit pipeline bubble");
        end
        @(negedge clock) ic_req_valid = 0;
        repeat (2) @(negedge clock);
        if (ar_count != reads_before) $fatal(1, "hit issued external reads");
        fetch_word(LINE-4, 1);

        // Leave an old miss in flight, cancel its waiter, then use a warm line.
        release_reads = 0;
        send(32'(SETS > 1 ? LINE : SETS*LINE), D);
        redirect_now();
        if (SETS > 1 || WAYS > 1) begin
            rsp_before = responses;
            fetch_word(0, D);
            if (responses != rsp_before+1) $fatal(1, "hit blocked behind old refill");
        end
        // Redirect while a hit response is visible, suppressing that exact event.
        if (SETS > 1 || WAYS > 1) begin
            @(negedge clock);
            ic_req_valid = 1;
            ic_req_payload = {gen, 4'(next_id), DCW'(D), 32'd0};
            @(posedge clock);
            if (!ic_req_ready) $fatal(1, "warm line unavailable");
            @(negedge clock);
            ic_req_valid = 0;
            redirect = 1;
            gen = gen+1'b1;
            next_id = 0;
            @(negedge clock) redirect = 0;
        end
        // A second distinct miss must backpressure until the old fill completes.
        @(negedge clock);
        ic_req_valid = 1;
        ic_req_payload = {gen, 4'(next_id), DCW'(D), 32'(2*SETS*LINE)};
        repeat (3) begin
            @(posedge clock);
            if (ic_req_ready) $fatal(1, "accepted second physical miss");
        end
        @(negedge clock);
        ic_req_valid = 0;
        // Join the old line under a new generation, without another refill.
        send(32'(SETS > 1 ? LINE : SETS*LINE), D);
        repeat (2) @(negedge clock);
        redirect_now();
        send(32'(SETS > 1 ? LINE : SETS*LINE), D);
        rsp_before = responses;
        @(negedge clock) release_reads = 1;
        while (responses == rsp_before) @(negedge clock);
        if (ar_count != reads_before+LINE/4) $fatal(1, "redirect duplicated or cancelled refill reads");

        // More conflicting lines than ways force replacement; probe every word.
        for (int line_no = 0; line_no < WAYS+2; line_no = line_no+1)
            fetch_word(32'((line_no+3)*SETS*LINE), D);
        reads_before = ar_count;
        fetch_word(32'((WAYS+4)*SETS*LINE+LINE-4), 1);
        if (ar_count != reads_before) $fatal(1, "installed line tail missed");
        fetch_word(0, D);
        if (ar_count != reads_before+LINE/4) $fatal(1, "conflict did not evict oldest line");

        // Keep issuing hits through refill completion; both response sources
        // must make progress without sharing or losing the response event.
        if (SETS > 1) begin
            reads_before = ar_count;
            missing_id = next_id;
            send(32'(9*SETS*LINE+LINE), D);
            for (int packet = 0; packet < 128; packet = packet+1) begin
                @(negedge clock);
                ic_req_valid = 1;
                ic_req_payload = {gen, 4'((missing_id+1)%16), DCW'(D), 32'd0};
                @(posedge clock);
                // The single SRAM write cycle may pause the hit stream once.
                if (!ic_req_ready) @(posedge clock);
                if (!ic_req_ready) $fatal(1, "hit stalled for more than the install cycle");
            end
            @(negedge clock) ic_req_valid = 0;
            repeat (2) @(negedge clock);
            if (ar_count != reads_before+LINE/4 || expected_valid != 0)
                $fatal(1, "hit/refill completion arbitration lost a response");
        end

        // Cancel on the exact cycle the installed miss response would return.
        reads_before = ar_count;
        send(32'(9*SETS*LINE), D);
        wait (ic_rsp_valid);
        @(negedge clock);
        redirect = 1;
        gen = gen+1'b1;
        next_id = 0;
        @(negedge clock) redirect = 0;
        fetch_word(32'(9*SETS*LINE), D);
        if (ar_count != reads_before+LINE/4) $fatal(1, "cancelled response lost installed line");

        // Redirect on the last physical R: the old fill must still install.
        reads_before = ar_count;
        send(32'(10*SETS*LINE), D);
        wait (if_rsp_valid && if_rsp_payload[32 +: IW] == IW'(LINE/4-1));
        @(negedge clock);
        redirect = 1;
        gen = gen+1'b1;
        next_id = 0;
        @(negedge clock) redirect = 0;
        fetch_word(32'(10*SETS*LINE), D);
        if (ar_count != reads_before+LINE/4) $fatal(1, "redirect dropped final physical response");
        loads = 0;
        while (load_pending != 0 || qcount != 0) @(negedge clock);
        if (load_responses == 0 || expected_valid != 0) $fatal(1, "missing responses");
        // Reset valid state without relying on cleared SRAM contents.
        @(negedge clock) reset = 1;
        repeat (2) @(negedge clock);
        reset = 0;
        reads_before = ar_count;
        fetch_word(0, D);
        if (ar_count != reads_before+LINE/4) $fatal(1, "reset retained valid cache data");
        $display("PASS icache D=%0d ways=%0d line=%0d sets=%0d", D, WAYS, LINE, SETS);
        done = 1;
    end
endmodule

module icache_test;
    wire [3:0] done;
    icache_case #(.D(1), .WAYS(1), .LINE(16)) c0(done[0]);
    icache_case #(.D(2), .WAYS(2), .LINE(32)) c1(done[1]);
    icache_case #(.D(4), .WAYS(4), .LINE(64)) c2(done[2]);
    icache_case #(.D(4), .WAYS(1), .LINE(16), .SETS(1)) c3(done[3]);
    initial begin
        wait (&done);
        $display("PASS all cache configurations");
        $finish;
    end
endmodule
